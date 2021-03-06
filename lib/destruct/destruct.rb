# frozen_string_literal: true

require 'unparser'
require_relative 'rule_sets/destruct'
require_relative './code_gen'
require_relative './util'

class Destruct
  include CodeGen

  NOTHING = make_singleton("#<NOTHING>")

  class << self
    def instance
      Thread.current[:destruct_cache_instance] ||= Destruct.new
    end

    def get_compiled(p, get_binding=nil)
      instance.get_compiled(p, get_binding)
    end

    def destruct(value, &block)
      instance.destruct(value, &block)
    end
  end

  def self.match(pat, x, binding=nil)
    if pat.is_a?(Proc)
      pat = RuleSets::StandardPattern.transform(binding: binding, &pat)
    end
    Compiler.compile(pat).match(x, binding)
  end

  def get_compiled(p, get_binding)
    @cpats_by_proc_id ||= {}
    key = p.source_location_id
    @cpats_by_proc_id.fetch(key) do
      binding = get_binding.call # obtaining the proc binding allocates heap, so only do so when necessary
      @cpats_by_proc_id[key] = Compiler.compile(RuleSets::StandardPattern.transform(binding: binding, &p))
    end
  end

  def destruct(value, &block)
    context = contexts.pop
    begin
      context.init(value) { block.binding }
      context.instance_exec(&block)
    ensure
      contexts.push(context)
    end
  end

  def contexts
    # Avoid allocations by keeping a stack for each thread. Maximum stack depth of 100 should be plenty.
    Thread.current[:destruct_contexts] ||= Array.new(100) { Context.new }
  end

  class Context
    # BE CAREFUL TO MAKE SURE THAT init() clears all instance vars

    def init(value, &get_outer_binding)
      @value = value
      @get_outer_binding = get_outer_binding
      @env = nil
      @outer_binding = nil
      @outer_self = nil
    end

    def match(&pat_proc)
      @env = Destruct.get_compiled(pat_proc, @get_outer_binding).match(@value)
    end

    def outer_binding
      @outer_binding ||= @get_outer_binding.call
    end

    def outer_self
      @outer_self ||= outer_binding.eval("self")
    end

    def method_missing(method, *args, &block)
      bound_value = @env.is_a?(Env) ? @env[method] : Env::UNBOUND
      if bound_value != Env::UNBOUND
        bound_value
      elsif outer_self
        outer_self.send method, *args, &block
      else
        super
      end
    end
  end
end

def destruct(value, &block)
  Destruct.destruct(value, &block)
end
