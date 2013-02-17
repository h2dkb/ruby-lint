require 'furnace/ast'

module RubyLint
  ##
  # {RubyLint::Node} is a class that represents a single node in the AST of a
  # Ruby program. It contains information such as the type, children, line
  # number and column number.
  #
  class Node < Furnace::AST::Node
    include VariablePredicates

    ##
    # Returns the line number of the node.
    #
    # @return [Fixnum]
    #
    attr_reader :line

    ##
    # Returns the column number of the node.
    #
    # @return [Fixnum]
    #
    attr_reader :column

    ##
    # Returns the name of the file that the node belongs to.
    #
    # @return [String]
    #
    attr_reader :file

    ##
    # @return [Array]
    #
    def to_a
      return children
    end

    ##
    # @return [String]
    #
    def name
      name = children[0] || type
      name = name.is_a?(Node) ? name.children[0] : name

      return name.to_s
    end

    ##
    # @return [Mixed]
    #
    def value
      value = collection? ? children : children[-1]
      value = children[1] if variable?

      return value
    end

    ##
    # Returns the receiver of the method call/definition.
    #
    # @return [RubyLint::Node]
    #
    def receiver
      return method? ? children[-1] : children[-2]
    end

    ##
    # Gathers a set of arguments and returns them as an Array.
    #
    # @param [#to_sym] type The type of arguments to gather.
    # @return [Array]
    #
    def gather_arguments(type)
      args = []
      type = type.to_sym

      children.each do |child|
        if !child.is_a?(Node) or child.type != :arguments
          next
        end

        child.children.each do |child_arg|
          next unless child_arg.type == type

          args << child_arg.children[0]
        end
      end

      return args
    end
  end # Node
end # RubyLint
