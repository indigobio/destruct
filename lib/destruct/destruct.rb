# frozen_string_literal: true

require 'unparser'
require_relative 'rule_sets/destruct'
require_relative './code_gen'
require_relative './util'

class Proc
  def cached_source_location
    @cached_source_location ||= source_location # don't allocate a new array every time
  end
end

class Destruct
  include CodeGen

  NOTHING = make_singleton("#<NOTHING>")

  class << self
    def destructs_by_proc
      Thread.current[:destructs_by_proc] ||= {}
    end

    def destruct(obj, rule_set=Destruct::RuleSets::StandardPattern, &block)
      if rule_set.is_a?(Class)
        rule_set = rule_set.instance
      end
      key = block.cached_source_location
      d = destructs_by_proc.fetch(key) do
        destructs_by_proc[key] = Destruct.new.compile(block, rule_set)
      end
      d.(obj, block)
    end
  end

  def compile(pat_proc, tx)
    case_expr = RuleSets::Destruct.transform(&pat_proc)
    source_file = pat_proc.source_location[0]
    input_name = case_expr.value ? Unparser.unparse(case_expr.value).to_sym : :_input
    emit_lambda("_x", "_obj_with_binding") do
      show_code_on_error do
        case_expr.whens.each do |w|
          w.preds.each do |pred|
            pat = tx.transform(pred, binding: pat_proc.binding)
            cp = Compiler.compile(pat)
            if_str = w == case_expr.whens.first && pred == w.preds.first ? "if" : "elsif"
            emit "#{if_str} _env = #{get_ref(cp.generated_code)}.proc.(_x, _obj_with_binding)"
            emit_body(w.body, input_name, cp.var_names, source_file)
          end
        end
        if case_expr.else_body
          emit "else"
          emit_body(case_expr.else_body, input_name, [], source_file)
        end
        emit "end"
      end
    end
    filename = "Destruct for #{pat_proc}"
    g = generate(filename)
    show_code(g)
    g.proc
  end

  def emit_body(body, input_name, var_names, source_file_path)
    redirected, needs_binding = redirect(body, [input_name, *var_names])
    params = [input_name, *var_names.map(&:to_s)]
    params << "_binding" if needs_binding
    code = StringIO.new
    code.puts "lambda do |#{params.join(", ")}|"
    code.puts Unparser.unparse(redirected)
    code.puts "end"
    code = code.string
    args = ["_x", *var_names.map { |name| "_env.#{name}" }]
    args << "_obj_with_binding.binding" if needs_binding
    body_proc = get_ref(eval(code, nil, source_file_path, body.location.line - 1))
    emit "#{body_proc}.(#{args.join(", ")})"
  end

  def self.match(pat, x, binding=nil)
    Compiler.compile(pat).match(x, binding)
  end

  private def redirect(node, var_names)
    @needs_binding = false
    [redir(node, var_names), @needs_binding]
  end

  private def redir(node, var_names)
    if !node.is_a?(Parser::AST::Node)
      node
    elsif (node.type == :lvar || node.type == :ivar) && !var_names.include?(node.children[0])
      @needs_binding = true
      n(:send, n(:lvar, :_binding), :eval, n(:str, node.children[0].to_s))
    elsif node.type == :send && node.children[0].nil? && !var_names.include?(node.children[1])
      @needs_binding = true
      self_expr = n(:send, n(:lvar, :_binding), :receiver)
      n(:send, self_expr, :send, n(:sym, node.children[1]), *node.children[2..-1].map { |c| redir(c, var_names) })
    else
      node.updated(nil, node.children.map { |c| redir(c, var_names) })
    end
  end

  def n(type, *children)
    Parser::AST::Node.new(type, children)
  end
end

def destruct(obj, rule_set=Destruct::RuleSets::StandardPattern, &block)
  Destruct.destruct(obj, rule_set, &block)
end
