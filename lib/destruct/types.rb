# frozen_string_literal: true

class Destruct
  Any = Object.new

  class Var
    attr_reader :name

    def initialize(name = nil)
      @name = name
    end

    def inspect
      "#<Var: #{name}>"
    end
    alias_method :to_s, :inspect
  end

  class Splat < Var
    def inspect
      "#<Splat: #{name}>"
    end
    alias_method :to_s, :inspect
  end

  class Let < Var
    attr_reader :pattern

    def initialize(name, pattern)
      super(name)
      @pattern = pattern
    end

    def inspect
      "#<Let: #{name} = #{pattern}>"
    end
    alias_method :to_s, :inspect
  end

  class Unquote
    attr_reader :code_expr

    def initialize(code_expr)
      @code_expr = code_expr
    end

    def inspect
      "#<Unquote: #{code_expr}>"
    end
    alias_method :to_s, :inspect
  end

  class Obj
    attr_reader :type, :fields

    def initialize(type, fields={})
      unless type.is_a?(Class) || type.is_a?(Module)
        raise "Obj type must be a Class or a Module, was: #{type}"
      end
      @type = type
      @fields = fields
    end

    def inspect
      "#<Obj: #{@type}[#{fields.map { |(k, v)| "#{k}: #{v}"}.join(", ")}]>"
    end
    alias_method :to_s, :inspect
  end

  class Or
    attr_reader :patterns

    def initialize(*patterns)
      @patterns = flatten(patterns)
    end

    def inspect
      "#<Or: #{patterns.map(&:inspect).join(", ")}>"
    end
    alias_method :to_s, :inspect

    private

    def flatten(ps)
      ps.inject([]) {|acc, p| p.is_a?(Or) ? acc + p.patterns : acc << p}
    end
  end
end
