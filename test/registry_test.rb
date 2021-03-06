# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'ruby_doozer'

# NOTE:
# This test assumes that doozerd is running locally on the default port of 8046

# Register an appender if one is not already registered
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('test.log') if SemanticLogger.appenders.size == 0

# Unit Test for RubyDoozer::Client
class RegistryTest < Test::Unit::TestCase
  context RubyDoozer::Registry do
    setup do
      @date      = Date.parse('2013-04-04')
      @time      = Time.at(1365102658).utc
      @test_data = {
        'bar'                     => 'test',
        'one'                     => 'one',
        'string_with_underscores' => 'and_a_value',
        'two'                     => :two,
        'integer'                 => 10,
        'float'                   => 10.5,
        'date'                    => @date,
        'time'                    => @time,
        'false'                   => false,
        'true'                    => true,
        'child'                   => { :symbol_with_underscores  => :and_a_value, :this => 'is', :an => ['array', :symbol, :smallest => {'a' => 'b', :c => :d}]}
      }
      @test_data['all_types'] = @test_data.dup
    end

    context "serialization" do
      setup do
        @json = {
          'bar'                     => 'test',
          'one'                     => 'one',
          'string_with_underscores' => 'and_a_value',
          'two'                     => ':two',
          'integer'                 => '10',
          'float'                   => '10.5',
          'date'                    => @date.to_s,
          'time'                    => @time.to_s,
          'false'                   => 'false',
          'true'                    => 'true',
          'child'                   => "{\":symbol_with_underscores\":\":and_a_value\",\":this\":\"is\",\":an\":[\"array\",\":symbol\",{\":smallest\":{\"a\":\"b\",\":c\":\":d\"}}]}",
          'all_types'               => "{\"bar\":\"test\",\"one\":\"one\",\"string_with_underscores\":\"and_a_value\",\"two\":\":two\",\"integer\":\"10\",\"float\":\"10.5\",\"date\":\"2013-04-04\",\"time\":\"2013-04-04 19:10:58 UTC\",\"false\":\"false\",\"true\":\"true\",\"child\":{\":symbol_with_underscores\":\":and_a_value\",\":this\":\"is\",\":an\":[\"array\",\":symbol\",{\":smallest\":{\"a\":\"b\",\":c\":\":d\"}}]}}"
        }
      end

      should ".serialize" do
        @test_data.each_pair do |k,v|
          assert_equal @json[k], RubyDoozer::Json::Serializer.serialize(v), "Key: #{k}"
        end
      end

      should ".deserialize" do
        @json.each_pair do |k,v|
          assert_equal @test_data[k], RubyDoozer::Json::Deserializer.deserialize(v), "Key: #{k}"
        end
      end
    end

    context "with registry" do
      setup do
        @registry = RubyDoozer::Registry.new(:root => "/registrytest")
        @test_data.each_pair {|k,v| @registry[k] = v}
      end

      def teardown
        if @registry
          @test_data.each_pair {|k,v| @registry.delete(k)}
          @registry.delete("three")
          @registry.finalize
        end
      end

      should "#[]" do
        @test_data.each_pair do |k,v|
          assert_equal v, @registry[k], "Expected #{k}=>#{v}, #{@registry.to_h.inspect}"
        end
      end

      should "#each_pair" do
        h = {}
        @registry.each_pair {|k,v| h[k] = v}
        assert_hash_equal @test_data, h
      end

      should "#to_h" do
        assert_hash_equal @test_data, @registry.to_h
      end

      should "#[]=" do
        @registry['three'] = 'value'
        # Give doozer time to send back the change
        sleep 0.3
        result = @registry['three']
        assert_equal 'value', result
      end

      [nil, '*'].each do |monitor_path|
        context "with monitor_path:#{monitor_path}" do
          should "callback on update" do
            updated_revision = nil
            updated_path = nil
            updated_value = nil
            @registry.on_update(monitor_path||'bar') do |path, value, revision|
              updated_revision = revision
              updated_path = path
              updated_value = value
            end
            # Allow monitoring thread to start
            sleep 0.1
            @registry['bar'] = 'updated'
            # Allow doozer to send back the change
            sleep 0.3
            assert_equal 'bar', updated_path
            assert_equal 'updated', updated_value
            assert_equal true, updated_revision > 0
          end

          should "callback on delete" do
            deleted_path = nil
            deleted_revision = nil
            @registry.on_delete(monitor_path||'bar') do |path, revision|
              deleted_path = path
              deleted_revision = revision
            end
            # Allow monitoring thread to start
            sleep 0.1
            # Allow doozer to send back the change
            @registry.delete('bar')
            sleep 0.3
            assert_equal 'bar', deleted_path
            assert_equal true, deleted_revision > 0
          end
        end
      end

      ['other', 'one'].each do |monitor_path|
        context "with monitor_path:#{monitor_path}" do
          should "not callback on update" do
            updated_path = nil
            updated_value = nil
            @registry.on_update(monitor_path) do |path, value|
              updated_path = path
              updated_value = value
            end
            # Allow monitoring thread to start
            sleep 0.1
            @registry['bar'] = 'updated'
            # Allow doozer to send back the change
            sleep 0.3
            assert_equal nil, updated_path
            assert_equal nil, updated_value
          end

          should "not callback on delete" do
            deleted_path = nil
            @registry.on_delete(monitor_path) do |path|
              deleted_path = path
            end
            # Allow monitoring thread to start
            sleep 0.1
            # Allow doozer to send back the change
            @registry.delete('bar')
            sleep 0.3
            assert_equal nil, deleted_path
          end
        end
      end

    end
  end

  # Verify that two hashes match
  def assert_hash_equal(expected, actual)
    expected.each_pair do |k,v|
      if v.is_a?(Hash)
        assert_hash_equal(v, actual[k])
      else
        assert_equal expected[k], actual[k], "Expected: #{expected.inspect}, Actual:#{actual.inspect}"
      end
    end
  end

end
