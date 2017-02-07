require_relative 'helpers'
require 'destructure'

class Foo
  attr_accessor :a, :b
  def initialize(a, b)
    @a, @b = a, b
  end
end

class Bar
  attr_accessor :x, :y
  def initialize(x, y)
    @x, @y = x, y
  end
end

class Baz
  attr_accessor :list
  def initialize(list)
    @list = list
  end

  def get(index)
    @list[index]
  end
end

class ZTest
  include Destructure

  def one(n, acc)
    dbind([1, n]) { [a, b] }
    acc.push b
    two(99, acc)
    acc.push b
    dbind([1, 1000]) { [a, b] }
    acc.push b
  end

  def two(n, acc)
    dbind([1, n]) { [a, b] }
    acc.push b
  end
end

describe 'Destructure#dbind' do

  context 'always' do

    include Destructure[bind_locals: false]
    include_context 'types'

    it 'should match non-local vars' do
      a = 1
      e = dbind(a) { x }
      expect(e.x).to eql 1
    end

    it 'should match local vars' do
      a = 1
      x = 99
      e = dbind(a) { x }
      expect(e.x).to eql 1
    end

    it 'should match symbols' do
      expect(dbind(:foo) { :foo }).to be_truthy
    end

    it 'should match arrays' do
      a = [1, 2, 3]
      e = dbind(a) { [1, x, 3] }
      expect(e.x).to eql 2
    end

    it 'should match hashes' do
      h = { a: 1, b: 2, c: 3}
      e = dbind(h) { { a: one, b: 2} }
      expect(e.one).to eql 1
    end

    it 'should match hashes with implicit binding' do
      h = { a: 1, b: 2, c: 3}
      e = dbind(h) { Hash[a, b, c] }
      expect(e.a).to eql 1
      expect(e.b).to eql 2
      expect(e.c).to eql 3
    end

    it 'should match regexps' do
      h = { a: 1, b: 'matching is the best' }
      e = dbind(h) { { a: 1, b: /(?<what>\w+) is the best/} }
      expect(e.what).to eql 'matching'

      h = { a: 1, b: 'ruby is the worst' }
      expect(dbind(h) { { a: 1, b: /(?<what>\w+) is the best/} }).to be_nil
    end

    it 'should match object types' do
      expect(dbind(5) { Numeric }).to be_truthy
      expect(dbind(99.999) { Numeric }).to be_truthy
      expect(dbind('hello') { Numeric }).to be_falsey
    end

    it 'should match object fields' do
      e = dbind(Foo.new(1, 2)) { Foo[a, b] }
      expect(e.a).to eql 1
      expect(e.b).to eql 2

      expect(dbind(Foo.new(3, 4)) { Foo[a: 3, b: b] }.b).to eql 4

      expect(dbind(Foo.new(3, 4)) { Foo[a: 99, b: b] }).to be_falsey
    end

    it 'should match splats' do
      a = [1,2,3,4,5,6,7,8,9]
      e = dbind(a) { [1, ~s, 9] }
      expect(e.s).to eql [2,3,4,5,6,7,8]
    end

    it 'should match deeply' do
      a = [ 100, { a: 1, b: 'hi', c: Bar.new(10, [13, 17, 23, 27, 29]) } ]
      e = dbind(a) { [ 100, { a: _, b: 'hi', c: Bar[x: ten, y: [_, 17, ~primes]] }, ~empty] }
      expect(e.ten).to eql 10
      expect(e.primes).to eql [ 23, 27, 29 ]
      expect(e.empty).to eql []
    end

    it 'should handle repeated vars' do
      e = dbind([1,2,1]) { [x,2,x] }
      expect(e.x).to eql 1

      expect(dbind([1,2,3]) { [x,2,x] }).to be_nil
    end

    it 'should handle alternative patterns' do
      expect(dbind([:foo, {a: :here}]) { [:foo | :bar, { a: :here | :there}] }).to be_truthy
      expect(dbind([:bar, {a: :there}]) { [:foo | :bar, { a: :here | :there}] }).to be_truthy
      expect(dbind([:huh, {a: :here}]) { [:foo | :bar, { a: :here | :there}] }).to be_falsey
      expect(dbind([:foo, {a: :huh}]) { [:foo | :bar, { a: :here | :there}] }).to be_falsey
    end

    it 'should handle let syntax' do
      e = dbind(['hello', 'starting']) { [ greeting = String, participle = /(?<verb>.*)ing$/ ] }
      expect(e.greeting).to eql 'hello'
      expect(e.participle).to eql 'starting'
      expect(e.verb).to eql 'start'

      e = dbind(['hello', 'has started']) { [ greeting = String, participle = /(?<verb>.*)ing$/ | /has (?<verb>.*)ed$/ ] }
      expect(e.greeting).to eql 'hello'
      expect(e.participle).to eql 'has started'
      expect(e.verb).to eql 'start'
    end

    it 'should handle literal variable values' do
      @my_var = 101
      foo = 7
      expect(dbind(5) { !5 }).to be_truthy
      expect(dbind(101) { !@my_var }).to be_truthy
      expect(dbind(7) { !foo }).to be_truthy
    end

    it 'should not warn about method conflicts' do
      dbind([1,2,3]) { [1,2,p] }  # Kernel#p
    end

  end


  context 'when binding locals' do

    include Destructure # binds locals by default

    it 'should set pre-initialized local variables' do
      a = 0
      dbind([1,2]) { [a, b] }
      expect(a).to eql 1
    end

    it 'should set non-literal local variables' do
      a = 0
      dbind([OpenStruct.new(hi: 'hello'), 2]) { [a, b] }
      expect(a).to be_instance_of OpenStruct
      expect(a.hi).to eql 'hello'
    end

    it 'should create methods for non-initialized local variables' do
      dbind([1,2]) { [a, b] }
      expect(b).to eql 2
    end

    it 'should ensure the fake locals maintain scope like real locals' do
      acc = []
      ZTest.new.one(3, acc)
      expect(acc).to eql [3, 99, 3, 1000]
    end

    it 'should make fake locals private' do
      f = ZTest.new
      f.one(3, [])
      expect { f.b }.to raise_error NoMethodError
    end

    it 'should restrict method_missing to only known values' do
      dbind([1,2]) { [a, b] }
      expect(b).to eql 2
      expect { self.c }.to raise_error NoMethodError
    end

    def important_method
      42
    end

    it 'should disallow non-local pattern variables with the same name as methods' do
      expect { dbind([1,2]) { [a, important_method] } }.to raise_error RuntimeError
    end

    it 'should return nil for non-matches' do
      expect(dbind([1,2]) { [5, b] }).to be_nil
    end

    it 'should bind to instance variables' do
      expect(@instance_var).to be_nil
      dbind([1, 7]) { [1, @instance_var] }
      expect(@instance_var).to eql 7
    end

    it 'should bind to complicated LHSs' do
      s = OpenStruct.new
      dbind([1, 7]) { [1, s.heyooo] }
      expect(s.heyooo).to eql 7

      h = {}
      dbind([1, 8]) { [1, h[:yelp]] }
      expect(h[:yelp]).to eql 8

      @one = OpenStruct.new
      @one.two = {}
      os2 = OpenStruct.new
      @one.two[:zzz] = Baz.new([0, 1, 2, os2])
      dbind([1, 9]) { [1, @one.two[:zzz].get(3).at_last] }
      expect(os2.at_last).to eql 9
    end

    it 'should accept complicated literals' do
      @one = OpenStruct.new
      @one.two = {}
      os2 = OpenStruct.new
      @one.two[:zzz] = Baz.new([0, 1, 2, os2])
      @one.two[:zzz].get(3).at_last = 9
      expect(dbind([1, 9]) { [1, !@one.two[:zzz].get(3).at_last] }).to be_truthy
      expect(dbind([1, 99999]) { [1, !@one.two[:zzz].get(3).at_last] }).to be_falsey
    end

    it 'should warn about method conflicts' do
      expect { dbind([1,2,3]) { [1,2,p] } }.to raise_error RuntimeError # Kernel#p
    end

  end


  context 'when specifying matcher' do
    include Destructure[:bind_locals => false, :matcher_name => :matches, :env_name => :m]

    it 'should work' do
      case [1,2,3]
        when matches { [4,5,x] }
          fail
        when matches { [1,2,x] }
          expect(m.x).to eql 3
        else
          fail
      end
    end
  end

  it 'should accept just a matcher name' do
    c = Class.new do
      include Destructure[:matcher_name => :asdf]

      def run
        case [1,2,3]
          when asdf { [4,5,x] }
            fail
          when asdf { [1,2,x] }
            expect(x).to eql 3
          else
            fail
        end
      end
    end
  end

  it 'should accept just an env name' do
    c = Class.new do
      include Destructure[:env_name => :eee]

      def run
        case
          when dbind([1,2,3]) { [4,5,x] }
            fail
          when dbind([1,2,3]) { [4,5,x] }
            expect(eee.x).to eql 3
          else
            fail
        end
      end
    end
  end
end
