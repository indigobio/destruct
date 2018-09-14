require_relative './transformer'

class Destruct
  module RuleSet
    Rule = Transformer::Rule

    def initialize
      @rules = []
    end

    def rules
      @rules.dup
    end

    def add_rule(pat_or_proc, constraints={}, &translate_block)
      translate =
          if constraints.any?
            proc do |**kws|
              constraints.each_pair do |var, const|
                unless as_array(kws[var]).all? { |p| as_array(const).any? { |type| p.is_a?(type) } }
                  raise Transformer::NotApplicable
                end
              end
              translate_block.(**kws)
            end
          else
            translate_block
          end
      if pat_or_proc.is_a?(Proc)
        node = ExprCache.get(pat_or_proc)
        pat = node_to_pattern(node)
        @rules.unshift(Rule.new(pat, translate))
      else
        @rules.unshift(Rule.new(pat_or_proc, translate))
      end
    end

    def as_array(x)
      if x.is_a?(Hash) || x.is_a?(Struct) || x.is_a?(Parser::AST::Node)
        [x]
      else
        Array(x)
      end
    end

    def node_to_pattern(node)
      if !node.is_a?(Parser::AST::Node)
        node
      else
        try_read_var(node) || try_read_splat(node) || try_read_lvasgn(node) ||
            just_node_to_pattern(node)
      end
    end

    def just_node_to_pattern(node)
      n(node.type, node.children.map { |c| node_to_pattern(c) })
    end

    def try_read_var(node)
      cp = Compiler.compile(any(n(:send, [nil, v(:name)]), n(:lvar, [v(:name)])))
      e = cp.match(node)
      if e
        puts "successfully matched var #{node}" if DEBUG
        Var.new(e[:name])
      else
        puts "failed to match var #{node}" if DEBUG
        nil
      end
    end

    def try_read_splat(node)
      cp = Compiler.compile(n(:splat, [any(n(:send, [nil, v(:name)]), n(:lvar, [v(:name)]))]))
      e = cp.match(node)
      if e
        puts "successfully matched splat #{node}" if DEBUG
        Splat.new(e[:name])
      else
        puts "failed to match splat #{node}" if DEBUG
        nil
      end
    end

    def try_read_lvasgn(node)
      cp = Compiler.compile(n(:lvasgn, [v(:lvar), v(:expr)]))
      e = cp.match(node)
      if e
        puts "successfully matched lvasgn #{node}" if DEBUG
        just_node_to_pattern(node.updated(nil, [Var.new(e[:lvar]), node_to_pattern(e[:expr])]))
      else
        puts "failed to match lvasgn #{node}" if DEBUG
        nil
      end
    end
  end
end
