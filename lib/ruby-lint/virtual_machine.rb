module RubyLint
  ##
  # {RubyLint::VirtualMachine} is the heart of ruby-lint. It takes a AST
  # generated by {RubyLint::Parser}, iterates it and builds various definitions
  # of methods, variables, etc.
  #
  # The virtual machine is a stack based virtual machine. Whenever certain
  # expressions are processed their values are stored in a stack which is then
  # later used for creating definitions (where applicable). For example, when
  # creating a new class a definition for the class is pushed on to a stack.
  # All code defined in this class is then stored in the definition at the end
  # of the stack.
  #
  # After a certain AST has been processed the VM will enter a read-only state
  # to prevent code from modifying it (either on purpose or by accident).
  #
  # ## Stacks
  #
  # The virtual machine uses two stacks:
  #
  # * `value_stack`
  # * `variable_stack`
  #
  # The value stack is used for storing raw values (e.g. integers) while the
  # variable stack is used for storing variable definitions (which in turn
  # store their values inside themselves).
  #
  # ## Definitions
  #
  # Built definitions are stored in {RubyLint::VirtualMachine#definitions} as a
  # single root definition called "root". This definition in turn contains
  # everything defined in a block of code that was processed by the VM.
  #
  # ## Associations
  #
  # The VM also keeps track of various nodes and their corresponding
  # definitions to make it easier to retrieve them later on. These are only
  # nodes/definitions related to a new scope such as a class or method
  # definition node.
  #
  # These associations are stored as a Hash in
  # {RubyLint::VirtualMachine#associations} with the keys set to the nodes and
  # the values to the corresponding definitions.
  #
  # ## Options
  #
  # The following extra options can be set in the constructor:
  #
  # * `:comments`: a Hash containing the comments for various AST nodes.
  #
  # @!attribute [r] associations
  #  @return [Hash]
  #
  # @!attribute [r] comments
  #  @return [Hash]
  #
  # @!attribute [r] definitions
  #  @return [RubyLint::Definition::RubyObject]
  #
  # @!attribute [r] extra_definitions
  #  @return [Array]
  #
  # @!attribute [r] value_stack
  #  @return [RubyLint::NestedStack]
  #
  # @!attribute [r] variable_stack
  #  @return [RubyLint::NestedStack]
  #
  # @!attribute [r] docstring_tags
  #  @return [RubyLint::Docstring::Mapping]
  #
  class VirtualMachine < Iterator
    include MethodEvaluation

    attr_reader :associations,
      :comments,
      :definitions,
      :docstring_tags,
      :value_stack,
      :variable_stack

    private :value_stack, :variable_stack, :docstring_tags

    ##
    # Hash containing variable assignment types and the corresponding variable
    # reference types.
    #
    # @return [Hash]
    #
    ASSIGNMENT_TYPES = {
      :lvasgn => :lvar,
      :ivasgn => :ivar,
      :cvasgn => :cvar,
      :gvasgn => :gvar
    }

    ##
    # Collection of primitive value types.
    #
    # @return [Array]
    #
    PRIMITIVES = [
      :int,
      :float,
      :str,
      :dstr,
      :sym,
      :regexp,
      :true,
      :false,
      :nil,
      :erange,
      :irange
    ]

    ##
    # Returns a Hash containing the method call evaluators to use for `(send)`
    # nodes.
    #
    # @return [Hash]
    #
    SEND_MAPPING = {
      '[]='           => MethodCall::AssignMember,
      'include'       => MethodCall::Include,
      'extend'        => MethodCall::Include,
      'alias_method'  => MethodCall::Alias,
      'attr'          => MethodCall::Attribute,
      'attr_reader'   => MethodCall::Attribute,
      'attr_writer'   => MethodCall::Attribute,
      'attr_accessor' => MethodCall::Attribute,
      'define_method' => MethodCall::DefineMethod
    }

    ##
    # Array containing the various argument types of method definitions.
    #
    # @return [Array]
    #
    ARGUMENT_TYPES = [:arg, :optarg, :restarg, :blockarg, :kwoptarg]

    ##
    # The types of variables to export outside of a method definition.
    #
    # @return [Array]
    #
    EXPORT_VARIABLES = [:ivar, :cvar, :const]

    ##
    # List of variable types that should be assigned in the global scope.
    #
    # @return [Array]
    #
    ASSIGN_GLOBAL = [:gvar]

    ##
    # The available method visibilities.
    #
    # @return [Array]
    #
    VISIBILITIES = [:public, :protected, :private].freeze

    ##
    # Called after a new instance of the virtual machine has been created.
    #
    def after_initialize
      @comments ||= {}

      @associations    = {}
      @definitions     = initial_definitions
      @constant_loader = ConstantLoader.new(:definitions => @definitions)
      @scopes          = [@definitions]
      @value_stack     = NestedStack.new
      @variable_stack  = NestedStack.new
      @ignored_nodes   = []
      @visibility      = :public

      reset_docstring_tags
      reset_method_type

      @constant_loader.bootstrap
    end

    ##
    # Processes the given AST or a collection of AST nodes.
    #
    # @see #iterate
    # @param [Array|RubyLint::AST::Node] ast
    #
    def run(ast)
      ast = [ast] unless ast.is_a?(Array)

      # pre-load all the built-in definitions.
      @constant_loader.run(ast)

      ast.each { |node| iterate(node) }

      freeze
    end

    ##
    # Freezes the VM along with all the instance variables.
    #
    def freeze
      @associations.freeze
      @definitions.freeze
      @scopes.freeze

      super
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_root(node)
      associate_node(node, current_scope)
    end

    ##
    # Processes a regular variable assignment.
    #
    def on_assign
      reset_assignment_value
      value_stack.add_stack
    end

    ##
    # @see #on_assign
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_assign(node)
      type  = ASSIGNMENT_TYPES[node.type]
      name  = node.children[0].to_s
      value = value_stack.pop.first

      if !value and assignment_value
        value = assignment_value
      end

      assign_variable(type, name, value, node)
    end

    ASSIGNMENT_TYPES.each do |callback, _|
      alias_method :"on_#{callback}", :on_assign
      alias_method :"after_#{callback}", :after_assign
    end

    ##
    # Processes the assignment of a constant.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_casgn(node)
      # Don't push values for the receiver constant.
      @ignored_nodes << node.children[0] if node.children[0]

      reset_assignment_value
      value_stack.add_stack
    end

    ##
    # @see #on_casgn
    #
    def after_casgn(node)
      values = value_stack.pop
      scope  = current_scope

      if node.children[0]
        scope = ConstantPath.new(node.children[0]).resolve(current_scope)

        return unless scope
      end

      variable = Definition::RubyObject.new(
        :type          => :const,
        :name          => node.children[1].to_s,
        :value         => values.first,
        :instance_type => :instance
      )

      add_variable(variable, scope)
    end

    def on_masgn
      add_stacks
    end

    ##
    # Processes a mass variable assignment using the stacks created by
    # {#on_masgn}.
    #
    def after_masgn
      variables = variable_stack.pop
      values    = value_stack.pop.first
      values    = values && values.value ? values.value : []

      variables.each_with_index do |variable, index|
        variable.value = values[index].value if values[index]

        current_scope.add(variable.type, variable.name, variable)
      end
    end

    def on_or_asgn
      add_stacks
    end

    ##
    # Processes an `or` assignment in the form of `variable ||= value`.
    #
    def after_or_asgn
      variable = variable_stack.pop.first
      value    = value_stack.pop.first

      if variable and value
        conditional_assignment(variable, value, false)
      end
    end

    def on_and_asgn
      add_stacks
    end

    ##
    # Processes an `and` assignment in the form of `variable &&= value`.
    #
    def after_and_asgn
      variable = variable_stack.pop.first
      value    = value_stack.pop.first

      conditional_assignment(variable, value)
    end

    # Creates the callback methods for various primitives such as integers.
    PRIMITIVES.each do |type|
      define_method("on_#{type}") do |node|
        push_value(create_primitive(node))
      end
    end

    # Creates the callback methods for various variable types such as local
    # variables.
    ASSIGNMENT_TYPES.each do |_, type|
      define_method("on_#{type}") do |node|
        increment_reference_amount(node)
        push_variable_value(node)
      end
    end

    ##
    # Called whenever a magic regexp global variable is referenced (e.g. `$1`).
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_nth_ref(node)
      var = definitions.lookup(:gvar, "$#{node.children[0]}")
      # If the number is not found, then add it as there is no limit for them
      var = definitions.define_global_variable(node.children[0]) if !var && node.children[0].is_a?(Fixnum)

      push_value(var.value)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def on_const(node)
      increment_reference_amount(node)
      push_variable_value(node)

      # The root node is also used in such a way that it processes child (=
      # receiver) constants.
      skip_child_nodes!(node)
    end

    ##
    # Adds a new stack for Array values.
    #
    def on_array
      value_stack.add_stack
    end

    ##
    # Builds an Array.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_array(node)
      builder = DefinitionBuilder::RubyArray.new(
        node,
        self,
        :values => value_stack.pop
      )

      push_value(builder.build)
    end

    ##
    # Adds a new stack for Hash values.
    #
    def on_hash
      value_stack.add_stack
    end

    ##
    # Builds a Hash.
    #
    # @param [RubyLint::AST::Node] node
    #
    def after_hash(node)
      builder = DefinitionBuilder::RubyHash.new(
        node,
        self,
        :values => value_stack.pop
      )

      push_value(builder.build)
    end

    ##
    # Adds a new value stack for key/value pairs.
    #
    def on_pair
      value_stack.add_stack
    end

    ##
    # @see #on_pair
    #
    def after_pair
      key, value = value_stack.pop

      return unless key

      member = Definition::RubyObject.new(
        :name  => key.value.to_s,
        :type  => :member,
        :value => value
      )

      push_value(member)
    end

    ##
    # Pushes the value of `self` onto the current stack.
    #
    def on_self
      scope  = current_scope
      method = scope.lookup(scope.method_call_type, 'self')

      push_value(method.return_value)
    end

    ##
    # Pushes the return value of the block yielded to, that is, an unknown one.
    #
    def on_yield
      push_unknown_value
    end

    ##
    # Creates the definition for a module.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_module(node)
      define_module(node, DefinitionBuilder::RubyModule)
    end

    ##
    # Pops the scope created by the module.
    #
    def after_module
      pop_scope
    end

    ##
    # Creates the definition for a class.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_class(node)
      parent      = nil
      parent_node = node.children[1]

      if parent_node
        parent = evaluate_node(parent_node)

        if !parent or !parent.const?
          # FIXME: this should use `definitions` instead.
          parent = current_scope.lookup(:const, 'Object')
        end
      end

      define_module(node, DefinitionBuilder::RubyClass, :parent => parent)
    end

    ##
    # Pops the scope created by the class.
    #
    def after_class
      pop_scope
    end

    ##
    # Builds the definition for a block.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_block(node)
      builder    = DefinitionBuilder::RubyBlock.new(node, self)
      definition = builder.build

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # Pops the scope created by the block.
    #
    def after_block
      pop_scope
    end

    ##
    # Processes an sclass block. Sclass blocks look like the following:
    #
    #     class << self
    #
    #     end
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_sclass(node)
      parent       = node.children[0]
      definition   = evaluate_node(parent)
      @method_type = definition.method_call_type

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # Pops the scope created by the `sclass` block and resets the method
    # definition/send type.
    #
    def after_sclass
      reset_method_type
      pop_scope
    end

    ##
    # Creates the definition for a method definition.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_def(node)
      receiver = nil

      if node.type == :defs
        receiver = evaluate_node(node.children[0])
      end

      builder = DefinitionBuilder::RubyMethod.new(
        node,
        self,
        :type       => @method_type,
        :receiver   => receiver,
        :visibility => @visibility
      )

      definition = builder.build

      builder.scope.add_definition(definition)

      associate_node(node, definition)

      buffer_docstring_tags(node)

      if docstring_tags and docstring_tags.return_tag
        assign_return_value_from_tag(
          docstring_tags.return_tag,
          definition
        )
      end

      push_scope(definition)
    end

    ##
    # Exports various variables to the outer scope of the method definition.
    #
    def after_def
      previous = pop_scope
      current  = current_scope

      reset_docstring_tags

      EXPORT_VARIABLES.each do |type|
        current.copy(previous, type)
      end
    end

    # Creates callbacks for various argument types such as :arg and :optarg.
    ARGUMENT_TYPES.each do |type|
      define_method("on_#{type}") do
        value_stack.add_stack
      end

      define_method("after_#{type}") do |node|
        value = value_stack.pop.first
        name  = node.children[0].to_s
        var   = Definition::RubyObject.new(
          :type          => :lvar,
          :name          => name,
          :value         => value,
          :instance_type => :instance
        )

        if docstring_tags and docstring_tags.param_tags[name]
          update_parents_from_tag(docstring_tags.param_tags[name], var)
        end

        associate_node(node, var)
        current_scope.add(type, name, var)
        current_scope.add_definition(var)
      end
    end

    alias_method :on_defs, :on_def
    alias_method :after_defs, :after_def

    ##
    # Processes a method call. If a certain method call has its own dedicated
    # callback that one will be called as well.
    #
    # @param [RubyLint::AST::Node] node
    #
    def on_send(node)
      name     = node.children[1].to_s
      name     = SEND_MAPPING.fetch(name, name)
      callback = "on_send_#{name}"

      value_stack.add_stack

      execute_callback(callback, node)
    end

    ##
    # @param [RubyLint::AST::Node] node
    #
    def after_send(node)
      receiver, name, _ = *node

      receiver    = unpack_block(receiver)
      name        = name.to_s
      args_length = node.children[2..-1].length
      values      = value_stack.pop
      arguments   = values.pop(args_length)
      block       = nil

      receiver_definition = values.first

      if arguments.length != args_length
        raise <<-EOF
Not enough argument definitions for #{node.inspect_oneline}.
Location: #{node.file} on line #{node.line}, column #{node.column}
Expected: #{args_length}
Received: #{arguments.length}
        EOF
      end

      # Associate the argument definitions with their nodes.
      arguments.each_with_index do |obj, index|
        arg_node = unpack_block(node.children[2 + index])

        associate_node(arg_node, obj)
      end

      # If the receiver doesn't exist there's no point in associating a context
      # with it.
      if receiver and !receiver_definition
        push_unknown_value

        return
      end

      if receiver and receiver_definition
        context = receiver_definition
      else
        context = current_scope

        # `parser` wraps (block) nodes around (send) calls which is a bit
        # inconvenient
        if context.block?
          block   = context
          context = previous_scope
        end
      end

      if SEND_MAPPING[name]
        evaluator = SEND_MAPPING[name].new(node, self)

        evaluator.evaluate(arguments, context, block)
      end

      # Associate the receiver node with the context so that it becomes
      # easier to retrieve later on.
      if receiver and context
        associate_node(receiver, context)
      end

      if context and context.method_defined?(name)
        retval = context.call_method(name)

        retval ? push_value(retval) : push_unknown_value

        # Track the method call
        track_method_call(context, name, node)
      else
        push_unknown_value
      end
    end

    VISIBILITIES.each do |vis|
      define_method("on_send_#{vis}") do
        @visibility = vis
      end
    end

    ##
    # Adds a new value stack for the values of an alias.
    #
    def on_alias
      value_stack.add_stack
    end

    ##
    # Processes calls to `alias`. Two types of data can be aliased:
    #
    # 1. Methods (using the syntax `alias ALIAS SOURCE`)
    # 2. Global variables
    #
    # This method dispatches the alias process to two possible methods:
    #
    # * on_alias_sym: aliasing methods (using symbols)
    # * on_alias_gvar: aliasing global variables
    #
    def after_alias(node)
      arguments = value_stack.pop
      evaluator = MethodCall::Alias.new(node, self)

      evaluator.evaluate(arguments, current_scope)
    end

    ##
    # @return [RubyLint::Definition::RubyObject]
    #
    def current_scope
      return @scopes.last
    end

    ##
    #
    # @return [RubyLint::Definition::RubyObject]
    #
    def previous_scope
      return @scopes[-2]
    end

    ##
    # @param [String] name
    # @return [RubyLint::Definition::RubyObject]
    #
    def global_constant(name)
      found = definitions.lookup(:const, name)

      # Didn't find it? Lets see if the constant loader knows about it.
      unless found
        @constant_loader.load_constant(name)

        found = definitions.lookup(:const, name)
      end

      return found
    end

    ##
    # Evaluates and returns the value of the given node.
    #
    # @param [RubyLint::AST::Node] node
    # @return [RubyLint::Definition::RubyObject]
    #
    def evaluate_node(node)
      value_stack.add_stack

      iterate(node)

      return value_stack.pop.first
    end

    private

    ##
    # Returns the initial set of definitions to use.
    #
    # @return [RubyLint::Definition::RubyObject]
    #
    def initial_definitions
      definitions = Definition::RubyObject.new(
        :name          => 'root',
        :type          => :root,
        :instance_type => :instance,
        :inherit_self  => false
      )

      definitions.parents = [
        definitions.constant_proxy('Object', RubyLint.registry)
      ]

      definitions.define_self

      return definitions
    end

    ##
    # Defines a new module/class based on the supplied node.
    #
    # @param [RubyLint::Node] node
    # @param [RubyLint::DefinitionBuilder::Base] definition_builder
    # @param [Hash] options
    #
    def define_module(node, definition_builder, options = {})
      builder    = definition_builder.new(node, self, options)
      definition = builder.build
      scope      = builder.scope
      existing   = scope.lookup(definition.type, definition.name, false)

      if existing
        definition = existing

        inherit_definition(definition, current_scope)
      else
        definition.add_definition(definition)

        scope.add_definition(definition)
      end

      associate_node(node, definition)

      push_scope(definition)
    end

    ##
    # Associates the given node and defintion with each other.
    #
    # @param [RubyLint::AST::Node] node
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def associate_node(node, definition)
      @associations[node] = definition
    end

    ##
    # Pushes a new scope on the list of available scopes.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def push_scope(definition)
      unless definition.is_a?(RubyLint::Definition::RubyObject)
        raise(
          ArgumentError,
          "Expected a RubyLint::Definition::RubyObject but got " \
            "#{definition.class} instead"
        )
      end

      @scopes << definition
    end

    ##
    # Removes a scope from the list.
    #
    def pop_scope
      raise 'Trying to pop an empty scope' if @scopes.empty?

      @scopes.pop
    end

    ##
    # Pushes the value of a variable onto the value stack.
    #
    # @param [RubyLint::AST::Node] node
    #
    def push_variable_value(node)
      return if value_stack.empty? || @ignored_nodes.include?(node)

      definition = definition_for_node(node)

      if definition
        value = definition.value ? definition.value : definition

        push_value(value)
      end
    end

    ##
    # Pushes a definition (of a value) onto the value stack.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def push_value(definition)
      value_stack.push(definition) if definition && !value_stack.empty?
    end

    ##
    # Pushes an unknown value object onto the value stack.
    #
    def push_unknown_value
      push_value(Definition::RubyObject.create_unknown)
    end

    ##
    # Adds a new variable and value stack.
    #
    def add_stacks
      variable_stack.add_stack
      value_stack.add_stack
    end

    ##
    # Assigns a basic variable.
    #
    # @param [Symbol] type The type of variable.
    # @param [String] name The name of the variable
    # @param [RubyLint::Definition::RubyObject] value
    # @param [RubyLint::AST::Node] node
    #
    def assign_variable(type, name, value, node)
      scope    = assignment_scope(type)
      variable = scope.lookup(type, name)

      # If there's already a variable we'll just update it.
      if variable
        variable.reference_amount += 1

        # `value` is not for conditional assignments as those are handled
        # manually.
        variable.value = value if value
      else
        variable = Definition::RubyObject.new(
          :type             => type,
          :name             => name,
          :value            => value,
          :instance_type    => :instance,
          :reference_amount => 0,
          :line             => node.line,
          :column           => node.column,
          :file             => node.file
        )
      end

      buffer_assignment_value(value)

      # Primarily used by #after_send to support variable assignments as method
      # call arguments.
      if value and !value_stack.empty?
        value_stack.push(variable.value)
      end

      add_variable(variable, scope)
    end

    ##
    # Determines the scope to use for a variable assignment.
    #
    # @param [Symbol] type
    # @return [RubyLint::Definition::RubyObject]
    #
    def assignment_scope(type)
      return ASSIGN_GLOBAL.include?(type) ? definitions : current_scope
    end

    ##
    # Adds a variable to the current scope of, if a the variable stack is not
    # empty, add it to the stack instead.
    #
    # @param [RubyLint::Definition::RubyObject] variable
    # @param [RubyLint::Definition::RubyObject] scope
    #
    def add_variable(variable, scope = current_scope)
      if variable_stack.empty?
        scope.add(variable.type, variable.name, variable)
      else
        variable_stack.push(variable)
      end
    end

    ##
    # Creates a primitive value such as an integer.
    #
    # @param [RubyLint::AST::Node] node
    # @param [Hash] options
    #
    def create_primitive(node, options = {})
      builder = DefinitionBuilder::Primitive.new(node, self, options)

      return builder.build
    end

    ##
    # Resets the variable used for storing the last assignment value.
    #
    def reset_assignment_value
      @assignment_value = nil
    end

    ##
    # Returns the value of the last assignment.
    #
    def assignment_value
      return @assignment_value
    end

    ##
    # Stores the value as the last assigned value.
    #
    # @param [RubyLint::Definition::RubyObject] value
    #
    def buffer_assignment_value(value)
      @assignment_value = value
    end

    ##
    # Resets the method assignment/call type.
    #
    def reset_method_type
      @method_type = :instance_method
    end

    ##
    # Performs a conditional assignment.
    #
    # @param [RubyLint::Definition::RubyObject] variable
    # @param [RubyLint::Definition::RubyValue] value
    # @param [TrueClass|FalseClass] bool When set to `true` existing variables
    #  will be overwritten.
    #
    def conditional_assignment(variable, value, bool = true)
      variable.reference_amount += 1

      if current_scope.has_definition?(variable.type, variable.name) == bool
        variable.value = value

        current_scope.add_definition(variable)

        buffer_assignment_value(variable.value)
      end
    end

    ##
    # Returns the definition for the given node.
    #
    # @param [RubyLint::AST::Node] node
    # @return [RubyLint::Definition::RubyObject]
    #
    def definition_for_node(node)
      if node.const? and node.children[0]
        definition = ConstantPath.new(node).resolve(current_scope)
      else
        definition = current_scope.lookup(node.type, node.name)
      end

      definition = Definition::RubyObject.create_unknown unless definition

      return definition
    end

    ##
    # Increments the reference amount of a node's definition unless the
    # definition is frozen.
    #
    # @param [RubyLint::AST::Node] node
    #
    def increment_reference_amount(node)
      definition = definition_for_node(node)

      if definition and !definition.frozen?
        definition.reference_amount += 1
      end
    end

    ##
    # Includes the definition `inherit` in the list of parent definitions of
    # `definition`.
    #
    # @param [RubyLint::Definition::RubyObject] definition
    # @param [RubyLint::Definition::RubyObject] inherit
    #
    def inherit_definition(definition, inherit)
      unless definition.parents.include?(inherit)
        definition.parents << inherit
      end
    end

    ##
    # Extracts all the docstring tags from the documentation of the given
    # node, retrieves the corresponding types and stores them for later use.
    #
    # @param [RubyLint::AST::Node] node
    #
    def buffer_docstring_tags(node)
      return unless comments[node]

      parser = Docstring::Parser.new
      tags   = parser.parse(comments[node].map(&:text))

      @docstring_tags = Docstring::Mapping.new(tags)
    end

    ##
    # Resets the docstring tags collection back to its initial value.
    #
    def reset_docstring_tags
      @docstring_tags = nil
    end

    ##
    # Updates the parents of a definition according to the types of a `@param`
    # tag.
    #
    # @param [RubyLint::Docstring::ParamTag] tag
    # @param [RubyLint::Definition::RubyObject] definition
    #
    def update_parents_from_tag(tag, definition)
      extra_parents = definitions_for_types(tag.types)

      definition.parents.concat(extra_parents)
    end

    ##
    # Creates an "unknown" definition with the given method in it.
    #
    # @param [String] name The name of the method to add.
    # @return [RubyLint::Definition::RubyObject]
    #
    def create_unknown_with_method(name)
      definition = Definition::RubyObject.create_unknown

      definition.send("define_#{@method_type}", name)

      return definition
    end

    ##
    # Returns a collection of definitions for a set of YARD types.
    #
    # @param [Array] types
    # @return [Array]
    #
    def definitions_for_types(types)
      definitions = []

      # There are basically two type signatures: either the name(s) of a
      # constant or a method in the form of `#method_name`.
      types.each do |type|
        if type[0] == '#'
          found = create_unknown_with_method(type[1..-1])
        else
          found = lookup_type_definition(type)
        end

        definitions << found if found
      end

      return definitions
    end

    ##
    # Tries to look up the given type/constant in the current scope and falls
    # back to the global scope if it couldn't be found in the former.
    #
    # @param [String] name
    # @return [RubyLint::Definition::RubyObject]
    #
    def lookup_type_definition(name)
      return current_scope.lookup(:const, name) || global_constant(name)
    end

    ##
    # @param [RubyLint::Docstring::ReturnTag] tag
    # @param [RubyLint::Definition::RubyMethod] definition
    #
    def assign_return_value_from_tag(tag, definition)
      definitions = definitions_for_types(tag.types)

      # THINK: currently ruby-lint assumes methods always return a single type
      # but YARD allows you to specify multiple ones. For now we'll take the
      # first one but there should be a nicer way to do this.
      definition.returns(definitions[0].instance) if definitions[0]
    end

    ##
    # Tracks a method call.
    #
    # @param [RubyLint::Definition::RubyMethod] definition
    # @param [String] name
    # @param [RubyLint::AST::Node] node
    #
    def track_method_call(definition, name, node)
      method   = definition.lookup(definition.method_call_type, name)
      current  = current_scope
      location = {
        :line   => node.line,
        :column => node.column,
        :file   => node.file
      }

      # Add the call to the current scope if we're dealing with a writable
      # method definition.
      if current.respond_to?(:calls) and !current.frozen?
        current.calls.push(
          MethodCallInfo.new(location.merge(:definition => method))
        )
      end

      # Add the caller to the called method, this allows for inverse lookups.
      unless method.frozen?
        method.callers.push(
          MethodCallInfo.new(location.merge(:definition => definition))
        )
      end
    end
  end # VirtualMachine
end # RubyLint
