# frozen_string_literal: true

require "pp"
require_relative './types'
require_relative './rbeautify'
require_relative './code_gen'
require "set"

class Destruct
  class Compiler
    include CodeGen

    class << self
      def compile(pat)
        if pat.is_a?(CompiledPattern)
          pat
        else
          compiled_patterns.fetch(pat) do
            compiled_patterns[pat] = begin
              cp = Compiler.new.compile(pat)
              on_compile_handlers.each { |h| h.(pat) }
              cp
            end
          end
        end
      end

      def compiled_patterns
        Thread.current[:destruct_compiled_patterns] ||= {}
      end

      def match(pat, x)
        compile(pat).match(x)
      end

      def on_compile(&block)
        on_compile_handlers << block
      end

      private def on_compile_handlers
        @on_compile_handlers ||= []
      end
    end

    Frame = Struct.new(:pat, :x, :env, :parent)

    Context = Struct.new(
        :s, # stack
        :pi) # previous instruction

    def add_instruction(ctx, inst)
      ctx.pi.and_then(inst)
      Context.new(ctx.s, inst)
    end

    class Instruction
      attr_reader :ps, # predecessors
                  :ss  # successors

      def initialize
        @ps = Set.new
        @ss = Set.new
      end

      def and_then(inst)
        ss.add(inst)
        inst.ps.add(self)
      end
    end

    class Noop < Instruction
      def initialize
        super
      end
    end

    class Test < Instruction
      attr_reader :lhs, :op, :rhs
      def initialize(lhs, op, rhs)
        super
        @lhs = lhs
        @op = op
        @rhs = rhs
      end
    end

    Ident = Struct.new(:name)

    # class Ident
    #   attr_reader :name, :value
    #
    #   def initialize(name, value)
    #     @name = name
    #     @value = value
    #   end
    # end

    def ident(prefix="t")
      Ident.new(get_temp(prefix))
    end

    def initialize
      @known_real_envs ||= Set.new
    end

    def compile(pat)
      @var_counts = var_counts(pat)
      @var_names = @var_counts.keys
      if @var_names.any?
        get_ref(::Destruct::Env.new_class(*@var_names).method(:new), "_make_env")
      end

      x = ident("x")
      binding = ident("binding")
      emit_lambda(x.name, binding.name) do
        show_code_on_error do
          c = apply(matcher(pat), x, true, binding)
          c = emit2(c)
          c = rra(c, {})
          c = rrtest(c)
          c = inline_stuff(c)
          c = emit3(c).join("\n")
          emit c
        end
      end
      g = generate("Matcher for: #{pat.inspect.gsub(/\s+/, " ")}")
      CompiledPattern.new(pat, g, @var_names)
    end

    def emit2(x)
      case x
      when Apply
        seq(x.proc.params.zip(x.args).map { |(p, a)| assign(p, a) } + [emit2(x.proc.body)])
      when Test
        tval = ident
        seq([assign(tval, emit2(x.cond)),
             test(tval, emit2(x.cons), emit2(x.alt))])
      when Eq
        eq(emit2(x.lhs), emit2(x.rhs))
      when is_literal_val?
        x
      when Ident
        x
      else
        if $debug_compile
          raise "emit2: unexpected: #{x.class}"
        else
          x
        end
      end
    end

    # remove redundant assignments
    def rra(x, map)
      case x
      when Seq
        seq(x.xs.map { |x| rra(x, map) })
      when Assign
        if x.rhs.is_a?(Ident) || literal_val?(x.rhs)
          map[x.lhs] = x.rhs
          noop
        else
          assign(rra(x.lhs, map), rra(x.rhs, map))
        end
      when Test
        test(rra(x.cond, map), rra(x.cons, map), rra(x.alt, map))
      when Ident
        map[x] || x
      when is_literal_val?
        x
      when Eq
        eq(rra(x.lhs, map), rra(x.rhs, map))
      else
        if $debug_compile
          raise "rra: unexpected: #{x.class}"
        else
          x
        end
      end
    end

    # remove redundant tests
    def rrtest(x)
      case x
      when Seq
        seq(x.xs.map { |x| rrtest(x) })
      when Assign
        assign(x.lhs, rrtest(x.rhs))
      when Eq
        eq(rrtest(x.lhs), rrtest(x.rhs))
      when is_literal_val?
        x
      when Ident
        x
      when Test
        if x.cons == true && !x.alt
          rrtest(x.cond)
        else
          test(rrtest(x.cond), rrtest(x.cons), rrtest(x.alt))
        end
      else
        if $debug_compile
          raise "rrif: unexpected: #{x.class}"
        else
          x
        end
      end
    end

    # inline stuff
    def inline_stuff(x)
      counts = Hash.new { |h, k| h[k] = 0 }
      map = {}
      count_refs(x, counts, map)
      map.delete_if { |k, _| counts[k] > 1 }
      inline(x, map)
    end

    def inline(x, map)
      case x
      when Seq
        seq(x.xs.map { |x| inline(x, map) })
      when Assign
        if map.keys.include?(x.lhs)
          noop
        else
          assign(x.lhs, inline(x.rhs, map))
        end
      when Test
        test(inline(x.cond, map), inline(x.cons, map), inline(x.alt, map))
      when Ident
        map[x] || x
      when is_literal_val?
        x
      when Eq
        eq(inline(x.lhs, map), inline(x.rhs, map))
      else
        raise "inline: unexpected: #{x.class}"
      end
    end

    def count_refs(x, counts, map)
      case x
      when Seq
        x.xs.each { |x| count_refs(x, counts, map) }
      when Assign
        map[x.lhs] = x.rhs
        count_refs(x.rhs, counts, map)
      when Eq
        count_refs(x.lhs, counts, map)
        count_refs(x.rhs, counts, map)
      when Ident
        counts[x] += 1
      when is_literal_val?
        # do nothing
      else
        raise "ref_counts: unexpected: #{x.class}" if $debug_compile
      end
    end

    def literal_val?(x)
      case x
      when TrueClass, FalseClass, NilClass, Numeric, String, Symbol
        true
      else
        false
      end
    end

    def is_literal_val?
      proc(&method(:literal_val?))
    end

    def emit3(x)
      case x
      when Assign
        ["#{eref(x.lhs)} = #{multival(emit3(x.rhs))}"]
      when Test
        [ "if #{eref(x.cond)}",
          *emit3(x.cons),
          "else",
          *emit3(x.alt),
          "end" ]
      when Eq
        [ "#{eref(x.lhs)} == #{eref(x.rhs)}" ]
      when Ident
        [eref(x)]
      when Seq
        x.xs.flat_map { |x| emit3(x) }
      when is_literal_val?
        [eref(x)]
      else
        raise "emit3: unexpected: #{x.class}"
      end
    end

    def multival(ss)
      if ss.size == 1
        ss.first
      else
        "(#{ss.join("; ")})"
      end
    end

    def eref(x)
      case x
      when Ident
        x.name
      when is_literal_val?
        x.inspect
      else
        if $debug_compile
          raise "eref: unexpected: #{x.class}"
        else
          get_ref(x)
        end
      end
    end

    def matcher(pat)
      value_matcher(pat)
    end

    def noop
      seq([])
    end

    Seq = Struct.new(:xs)

    def seq(xs)
      Seq.new(xs)
    end

    def value_matcher(pat)
      x = ident("x")
      env = ident("env")
      binding = ident("binding")
      lm([x, env, binding], test(eq(x, pat), env, nil))
    end

    Assign = Struct.new(:lhs, :rhs)

    def assign(lhs, rhs)
      Assign.new(lhs, rhs)
    end

    Apply = Struct.new(:proc, :args)

    def apply(proc, *args)
      Apply.new(proc, args)
    end

    Lambda = Struct.new(:params, :body)

    def lm(params, body)
      Lambda.new(params, body)
    end

    Test = Struct.new(:cond, :cons, :alt)

    def test(cond, cons, alt)
      Test.new(cond, cons, alt)
    end

    Eq = Struct.new(:lhs, :rhs)

    def eq(lhs, rhs)
      Eq.new(lhs, rhs)
    end

    def var_counts(pat)
      find_var_names_non_uniq(pat).group_by(&:itself).map { |k, vs| [k, vs.size] }.to_h
    end

    def find_var_names_non_uniq(pat)
      if pat.is_a?(Obj)
        pat.fields.values.flat_map(&method(:find_var_names_non_uniq))
      elsif pat.is_a?(Or)
        @has_or = true
        pat.patterns.flat_map(&method(:find_var_names_non_uniq))
      elsif pat.is_a?(Let)
        [pat.name, *find_var_names_non_uniq(pat.pattern)]
      elsif pat.is_a?(Binder)
        [pat.name]
      elsif pat.is_a?(Hash)
        pat.values.flat_map(&method(:find_var_names_non_uniq))
      elsif pat.is_a?(Array)
        pat.flat_map(&method(:find_var_names_non_uniq))
      elsif pat.is_a?(Regexp)
        pat.named_captures.keys.map(&:to_sym)
      else
        []
      end
    end

    def match(pat)
      # if s.pat == Any
      #   # do nothing
      # elsif s.pat.is_a?(Obj)
      #   match_obj(s)
      # elsif s.pat.is_a?(Or)
      #   match_or(s)
      # elsif s.pat.is_a?(Let)
      #   match_let(s)
      # elsif s.pat.is_a?(Var)
      #   match_var(s)
      # elsif s.pat.is_a?(Unquote)
      #   match_unquote(s)
      # elsif s.pat.is_a?(Hash)
      #   match_hash(s)
      # elsif s.pat.is_a?(Array)
      #   match_array(s)
      # elsif s.pat.is_a?(Regexp)
      #   match_regexp(s)
      # elsif is_literal_val?(s.pat)
      #   match_literal(s)
      # elsif
      #   match_other(s)
      # end
      match_value(cts)
    end

    def match_value(ctx)
      add_instruction(ctx, Test.new(ctx.s.pat, :==, ctx.s.x))
      add_instruction(ctx, Ref.new(ctx.s.env))
    end

    # def is_literal_val?(x)
    #   x.is_a?(Numeric) || x.is_a?(String) || x.is_a?(Symbol)
    # end

    def is_literal_pat?(p)
      !(p.is_a?(Obj) ||
          p.is_a?(Or) ||
          p.is_a?(Binder) ||
          p.is_a?(Unquote) ||
          p.is_a?(Hash) ||
          p.is_a?(Array))
    end

    def pattern_order(p)
      # check the cheapest or most likely to fail first
      if is_literal_pat?(p)
        0
      elsif p.is_a?(Or) || p.is_a?(Regexp)
        2
      elsif p.is_a?(Binder)
        3
      elsif p.is_a?(Unquote)
        4
      else
        1
      end
    end

    def match_array(s)
      s.type = :array
      splat_count = s.pat.count { |p| p.is_a?(Splat) }
      if splat_count > 1
        raise "An array pattern cannot have more than one splat: #{s.pat}"
      end
      splat_index = s.pat.find_index { |p| p.is_a?(Splat) }
      is_closed = !splat_index || splat_index != s.pat.size - 1
      pre_splat_range = 0...(splat_index || s.pat.size)

      s.x = localize(nil, s.x)
      known_real_envs_before = @known_real_envs.dup
      emit_if "#{s.x}.is_a?(Array)" do
        cond = splat_index ? "#{s.x}.size >= #{s.pat.size - 1}" : "#{s.x}.size == #{s.pat.size}"
        test(s, cond) do

          pre_splat_range
              .map { |i| [s.pat[i], i] }
              .sort_by { |(item_pat, i)| [pattern_order(item_pat), i] }
              .each do |item_pat, i|
            x = localize(item_pat, "#{s.x}[#{i}]")
            match(Frame.new(item_pat, x, s.env, s))
          end

          if splat_index
            splat_range = get_temp("splat_range")
            post_splat_width = s.pat.size - splat_index - 1
            emit "#{splat_range} = #{splat_index}...(#{s.x}.size#{post_splat_width > 0 ? "- #{post_splat_width}" : ""})"
            bind(s, s.pat[splat_index], "#{s.x}[#{splat_range}]")

            post_splat_pat_range = ((splat_index + 1)...s.pat.size)
            post_splat_pat_range.each do |i|
              item_pat = s.pat[i]
              x = localize(item_pat, "#{s.x}[-#{s.pat.size - i}]")
              match(Frame.new(item_pat, x, s.env, s))
            end
          end
        end
      end.elsif "#{s.x}.is_a?(Enumerable)" do
        @known_real_envs = known_real_envs_before
        en = get_temp("en")
        done = get_temp("done")
        stopped = get_temp("stopped")
        emit "#{en} = #{s.x}.each"
        emit "#{done} = false"
        emit_begin do
          s.pat[0...(splat_index || s.pat.size)].each do |item_pat|
            x = localize(item_pat, "#{en}.next")
            match(Frame.new(item_pat, x, s.env, s))
          end

          if splat_index
            if is_closed
              splat = get_temp("splat")
              emit "#{splat} = []"
              splat_len = get_temp("splat_len")
              emit "#{splat_len} = #{s.x}.size - #{s.pat.size - 1}"
              emit "#{splat_len}.times do"
              emit "#{splat} << #{en}.next"
              emit "end"
              bind(s, s.pat[splat_index], splat)

              s.pat[(splat_index+1)...(s.pat.size)].each do |item_pat|
                x = localize(item_pat, "#{en}.next")
                match(Frame.new(item_pat, x, s.env, s))
              end
            else
              bind(s, s.pat[splat_index], "#{en}.new_from_here")
            end
          end

          emit "#{done} = true"
          emit "#{en}.next" if is_closed
        end.rescue "StopIteration" do
          emit "#{stopped} = true"
          test(s, done)
        end.end
        test(s, stopped) if is_closed
      end.else do
        test(s, "nil")
      end
    end

    def in_or(s)
      !s.nil? && (s.type == :or || in_or(s.parent))
    end

    def match_regexp(s)
      s.type = :regexp
      m = get_temp("m")
      match_env = get_temp("env")
      test(s, "#{s.x}.is_a?(String) || #{s.x}.is_a?(Symbol)") do
        emit "#{m} = #{get_ref(s.pat)}.match(#{s.x})"
        emit "#{match_env} = ::Destruct::Env.new(#{m}) if #{m}"
        test(s, match_env)
        merge(s, match_env, dynamic: true)
      end
    end

    def match_literal(s)
      s.type = :literal
      test(s, "#{s.x} == #{s.pat.inspect}")
    end

    def match_other(s)
      s.type = :other
      test(s, "#{s.x} == #{get_ref(s.pat)}")
    end

    # def test(s, cond)
    #   # emit "puts \"line #{emitted_line_count + 8}: \#{#{cond.inspect}}\""
    #   emit "puts \"test: \#{#{cond.inspect}}\"" if $show_tests
    #   if in_or(s)
    #     emit "#{s.env} = (#{cond}) ? #{s.env} : nil if #{s.env}"
    #     if block_given?
    #       emit_if s.env do
    #         yield
    #       end.end
    #     end
    #   elsif cond == "nil" || cond == "false"
    #     emit "return nil"
    #   else
    #     emit "#{cond} or return nil"
    #     yield if block_given?
    #   end
    # end

    def match_var(s)
      s.type = :var
      test(s, "#{s.x} != #{nothing_ref}")
      bind(s, s.pat, s.x)
    end

    def match_unquote(s)
      temp_env = get_temp("env")
      emit "raise 'binding must be provided' if _binding.nil?"
      emit "#{temp_env} = ::Destruct.match(_binding.eval('#{s.pat.code_expr}'), #{s.x}, _binding)"
      test(s, temp_env)
      merge(s, temp_env, dynamic: true)
    end

    def match_let(s)
      s.type = :let
      match(Frame.new(s.pat.pattern, s.x, s.env, s))
      bind(s, s.pat, s.x)
    end

    def bind(s, var, val, val_could_be_unbound_sentinel=false)
      var_name = var.is_a?(Binder) ? var.name : var

      # emit "# bind #{var_name}"
      proposed_val =
          if val_could_be_unbound_sentinel
            # we'll want this in a local because the additional `if` clause below will need the value a second time.
            pv = get_temp("proposed_val")
            emit "#{pv} = #{val}"
            pv
          else
            val
          end

      do_it = proc do
        unless @known_real_envs.include?(s.env)
          # no need to ensure the env is real (i.e., an Env, not `true`) if it's already been ensured
          emit "#{s.env} = _make_env.() if #{s.env} == true"
          @known_real_envs.add(s.env) unless in_or(s)
        end
        current_val = "#{s.env}.#{var_name}"
        if @var_counts[var_name] > 1
          # if the pattern binds the var in two places, we'll have to check if it's already bound
          emit_if "#{current_val} == :__unbound__" do
            emit "#{s.env}.#{var_name} = #{proposed_val}"
          end.elsif "#{current_val} != #{proposed_val}" do
            if in_or(s)
              emit "#{s.env} = nil"
            else
              test(s, "nil")
            end
          end.end
        else
          # otherwise, this is the only place we'll attempt to bind this var, so just do it
          emit "#{current_val} = #{proposed_val}"
        end
      end

      if in_or(s)
        emit_if("#{s.env}", &do_it).end
      elsif val_could_be_unbound_sentinel
        emit_if("#{s.env} && #{proposed_val} != :__unbound__", &do_it).end
      else
        do_it.()
      end

      test(s, "#{s.env}") if in_or(s)
    end

    def match_obj(s)
      s.type = :obj
      match_hash_or_obj(s, get_ref(s.pat.type), s.pat.fields, proc { |field_name| "#{s.x}.#{field_name}" })
    end

    def match_hash(s)
      s.type = :hash
      match_hash_or_obj(s, "Hash", s.pat, proc { |field_name| "#{s.x}.fetch(#{field_name.inspect}, #{nothing_ref})" })
    end

    def nothing_ref
      get_ref(::Destruct::NOTHING)
    end

    def match_hash_or_obj(s, type_str, pairs, make_x_sub)
      test(s, "#{s.x}.is_a?(#{type_str})") do
        pairs
            .sort_by { |(_, field_pat)| pattern_order(field_pat) }
            .each do |field_name, field_pat|
          x = localize(field_pat, make_x_sub.(field_name), field_name)
          # xv = get_ref("xv")
          # emit("#{xv} = #{x}")
          # test(s, "#{xv} != #{nothing_ref}")
          match(Frame.new(field_pat, x, s.env, s))
        end
      end
    end

    def multi?(pat)
      pat.is_a?(Or) ||
          (pat.is_a?(Array) && pat.size > 1) ||
          pat.is_a?(Obj) && pat.fields.any?
    end

    def match_or(s)
      s.type = :or
      closers = []
      or_env = get_temp("env")
      emit "#{or_env} = true"
      s.pat.patterns.each_with_index do |alt, i|
        match(Frame.new(alt, s.x, or_env, s))
        if i < s.pat.patterns.size - 1
          emit "unless #{or_env}"
          closers << proc { emit "end" }
          emit "#{or_env} = true"
        end
      end
      closers.each(&:call)
      merge(s, or_env)
      emit "#{s.env} or return nil" if !in_or(s.parent)
    end

    def merge(s, other_env, dynamic: false)
      @known_real_envs.include?(s.env)

      emit_if("#{s.env}.nil? || #{other_env}.nil?") do
        emit "#{s.env} = nil"
      end.elsif("#{s.env} == true") do
        emit "#{s.env} = #{other_env}"
      end.elsif("#{other_env} != true") do
        if dynamic
          emit "#{other_env}.env_each do |k, v|"
          emit_if("#{s.env}[k] == :__unbound__") do
            emit "#{s.env}[k] = v"
          end.elsif("#{s.env}[k] != v") do
            if in_or(s)
              emit "#{s.env} = nil"
            else
              test(s, "nil")
            end
          end.end
          emit "end"
        else
          @var_names.each do |var_name|
            bind(s, var_name, "#{other_env}.#{var_name}", true)
          end
        end
      end.end
    end

    private

    def localize(pat, x, prefix="t")
      if (pat.nil? && x =~ /\.\[\]/) || multi?(pat) || (pat.is_a?(Binder) && x =~ /\.fetch|\.next/)
        t = get_temp(prefix)
        emit "#{t} = #{x}"
        x = t
      end
      x
    end
  end

  class Pattern
    attr_reader :pat

    def initialize(pat)
      @pat = pat
    end

    def to_s
      "#<Pattern #{pat}>"
    end

    alias_method :inspect, :to_s

    def match(x, binding=nil)
      Compiler.compile(pat).match(x, binding)
    end
  end

  class CompiledPattern
    attr_reader :pat, :generated_code, :var_names

    def initialize(pat, generated_code, var_names)
      @pat = pat
      @generated_code = generated_code
      @var_names = var_names
    end

    def match(x, binding=nil)
      @generated_code.proc.(x, binding)
    end

    def show_code
      generated_code.show
    end
  end
end

module Enumerable
  def rest
    result = []
    while true
      result << self.next
    end
  rescue StopIteration
    result
  end

  def new_from_here
    orig = self
    WrappedEnumerator.new(orig) do |y|
      while true
        y << orig.next
      end
    end
  end
end

class WrappedEnumerator < Enumerator
  def initialize(inner, &block)
    super(&block)
    @inner = inner
  end

  def new_from_here
    orig = @inner
    WrappedEnumerator.new(orig) do |y|
      while true
        y << orig.next
      end
    end
  end
end
