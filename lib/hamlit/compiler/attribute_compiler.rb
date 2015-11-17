require 'hamlit/attribute_builder'
require 'hamlit/hash_parser'
require 'hamlit/static_analyzer'

module Hamlit
  class Compiler
    class AttributeCompiler
      def initialize(options = {})
        @quote  = options[:attr_quote]
        @format = options[:format]
        @escape_attrs = options[:escape_attrs]
      end

      def compile(node)
        hashes = []
        return runtime_compile(node) if node.value[:object_ref] != :nil
        node.value[:attributes_hashes].each do |attribute_str|
          hash = HashParser.parse(attribute_str)
          return runtime_compile(node) unless hash
          hashes << hash
        end
        static_compile(node.value[:attributes], hashes)
      end

      private

      def runtime_compile(node)
        attrs = node.value[:attributes_hashes]
        attrs.unshift(node.value[:attributes].inspect) if node.value[:attributes] != {}

        args = [@escape_attrs, @quote, @format].map(&:inspect).push(node.value[:object_ref]) + attrs
        [:html, :attrs, [:dynamic, "::Hamlit::AttributeBuilder.build(#{args.join(', ')})"]]
      end

      def static_compile(static_hash, dynamic_hashes)
        temple = [:html, :attrs]
        keys = [*static_hash.keys, *dynamic_hashes.map(&:keys).flatten].uniq.sort
        keys.each do |key|
          values = [[:static, static_hash[key]], *dynamic_hashes.map { |h| [:dynamic, h[key]] }]
          values.select! { |_, exp| exp != nil }

          case key
          when 'id'.freeze
            compile_id!(temple, key, values)
          when 'class'.freeze
            compile_class!(temple, key, values)
          when 'data'.freeze
            compile_data!(temple, key, values)
          when *AttributeBuilder::BOOLEAN_ATTRIBUTES, *AttributeBuilder::DATA_BOOLEAN_ATTRIBUTES
            compile_boolean!(temple, key, values)
          else
            compile_common!(temple, key, values)
          end
        end
        temple
      end

      def compile_id!(temple, key, values)
        build_code = attribute_builder(:id, values)
        if values.all? { |type, exp| type == :static || StaticAnalyzer.static?(exp) }
          temple << [:html, :attr, key, [:static, eval(build_code)]]
        else
          temple << [:html, :attr, key, [:dynamic, build_code]]
        end
      end

      def compile_class!(temple, key, values)
        # NOTE: Haml does not sort classes if static
        if values.all? { |type, _| type == :static }
          values.each { |v| temple << build_attr(key, *v) }
          return
        end

        build_code = attribute_builder(:class, values)
        if values.all? { |type, exp| type == :static || StaticAnalyzer.static?(exp) }
          temple << [:html, :attr, key, [:static, eval(build_code)]]
        else
          temple << [:html, :attr, key, [:dynamic, build_code]]
        end
      end

      def compile_data!(temple, key, values)
        args = [@escape_attrs.inspect, @quote.inspect, values.map { |v| literal_for(v) }]
        build_code = "::Hamlit::AttributeBuilder.build_data(#{args.join(', ')})"

        if values.all? { |type, exp| type == :static || StaticAnalyzer.static?(exp) }
          temple << [:static, eval(build_code)]
        else
          temple << [:dynamic, build_code]
        end
      end

      def compile_boolean!(temple, key, values)
        exp = literal_for(values.last)
        build_code = boolean_builder(key, exp)

        if StaticAnalyzer.static?(exp)
          temple << [:static, eval(['_buf = []', build_code, '_buf.join'].join('; '))]
        else
          temple << [:code, build_code]
        end
      end

      def compile_common!(temple, key, values)
        type, exp = values.last

        if type == :dynamic && StaticAnalyzer.static?(exp)
          type, exp = :static, eval("(#{exp}).to_s")
        end
        temple << build_attr(key, type, exp)
      end

      def build_attr(key, type, exp)
        [:html, :attr, key, [:escape, @escape_attrs, [type, exp]]]
      end

      def attribute_builder(type, values)
        args = [@escape_attrs.inspect, *values.map { |v| literal_for(v) }]
        "::Hamlit::AttributeBuilder.build_#{type}(#{args.join(', ')})"
      end

      def boolean_builder(key, exp)
        [
          %Q|case #{exp}|,
          %q|when true|,
            %Q|_buf << #{ (@format == :xhtml ? " #{key}=#{@quote}#{key}#{@quote}" : " #{key}").inspect }.freeze|,
          %q|when false, nil|,
            # omitted
          %q|else|,
            %Q|_buf << #{ " #{key}=#{@quote}".inspect }.freeze|,
            %Q|_buf << #{ @escape_attrs ? "::Temple::Utils.escape_html((#{exp}))" : exp }|,
            %Q|_buf << #{@quote.inspect}.freeze|,
          %q|end|,
        ].join('; ')
      end

      def literal_for(value)
        type, exp = value
        type == :static ? exp.inspect : exp
      end
    end
  end
end
