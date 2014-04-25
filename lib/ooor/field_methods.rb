require 'active_support/concern'

module Ooor
  module FieldMethods
    extend ActiveSupport::Concern

    module ClassMethods

      def reload_fields_definition(force=false)
        if force || !fields
          @t.fields = {}
          @columns_hash = {}
          fields_get = rpc_execute("fields_get", false, context)
          fields_get.each { |k, field| reload_field_definition(k, field) }
          @t.associations_keys = many2one_associations.keys + one2many_associations.keys + many2many_associations.keys + polymorphic_m2o_associations.keys
          logger.debug "#{fields.size} fields loaded in model #{self.name}"
          Ooor.model_registry.set_template(session.config, @t)
        end
        generate_accessors if fields != {} && (force || !@accessor_defined) #TODOmove in define_accessors method
      end

      def all_fields
        fields.merge(polymorphic_m2o_associations).merge(many2many_associations).merge(one2many_associations).merge(many2one_associations)
      end

      def fast_fields(options={})
        fields = all_fields
        fields.keys.select do |k|
          fields[k]["type"] != "binary" && (options[:include_functions] || !fields[k]["function"])
        end
      end
      
      private

      def generate_accessors #TODO we should cache this is a module cached like the template, or eventually generate source code or both
        fields.keys.each { |meth| define_field_method meth }
        associations_keys.each { |meth| define_association_method meth }
        one2many_associations.keys.each { |meth| accepts_nested_attributes_for meth } #TODO do it for m2o too
        many2one_associations.keys.each do |meth|
          define_association_method meth
          define_m2o_association_method meth
        end
        (one2many_associations.keys + many2many_associations.keys).each do |meth|
          define_association_method meth
          alias_method "#{meth}_ids", meth
          alias_method "#{meth}_ids=", "#{meth}="
          alias_method "#{meth.to_s.singularize}_ids", meth
          alias_method "#{meth.to_s.singularize}_ids=", "#{meth}="
        end
        @accessor_defined = true
      end

      def define_field_method(meth)
        define_attribute_methods meth
        define_method meth do |*args|
          get_attribute(meth, *args)
        end

        define_method "#{meth}=" do |*args|
          set_attribute(meth, *args)
        end
      end

      def define_association_method(meth)
        define_attribute_methods meth
        define_method meth do |*args|
          get_association(meth, *args)
        end

        define_method "#{meth}=" do |*args|
          set_association(meth, *args)
        end
      end

      def define_m2o_association_method(meth)
        define_method "#{meth}_id" do |*args|
          if @associations[meth].is_a? Array
            @associations[meth][0]
          else
            r = get_association(meth, *args)
            r.is_a?(Ooor::Base) ? r.id : r
          end
        end
      end

      def reload_field_definition(k, field)
        case field['type']
        when 'many2one'
          many2one_associations[k] = field
        when 'one2many'
          one2many_associations[k] = field
        when 'many2many'
          many2many_associations[k] = field
        when 'reference'
          polymorphic_m2o_associations[k] = field
        else
          fields[k] = field if field['name'] != 'id'
        end
      end

    end

    def get_attribute(meth, *args)
      if @attributes.has_key?(meth)
        @attributes[meth]
      else #lazy loading
        if @attributes["id"]
          @attributes[meth] = rpc_execute('read', [@attributes["id"]], [meth], *args || context)[0][meth]
        else
          nil
        end
      end
    end

    def set_attribute(meth, *args)
      value = sanitize_attribute(meth, args[0])
      @attributes[meth] ||= nil
      send("#{meth}_will_change!") unless @attributes[meth] == value
      @attributes[meth] = value
    end

    def get_association(meth, *args)
      return @associations[meth] || :undef if @skip
      if @loaded_associations.has_key?(meth)
        @loaded_associations[meth]
      elsif @associations.has_key?(meth)
        @loaded_associations[meth] = relationnal_result(meth, *args)
      else
        if @attributes["id"]
          @associations[meth] = rpc_execute('read', [@attributes["id"]], [meth], *args || context)[0][meth]
          @loaded_associations[meth] = relationnal_result(meth, *args)
        elsif self.class.one2many_associations.has_key?(meth) || self.class.many2many_associations.has_key?(meth)
          load_x2m_association(self.class.all_fields[meth]['relation'], [], *args)
        else
          nil
        end
      end
    end

    def set_association(meth, *args)
      value = sanitize_association(meth, args[0])
      if self.class.many2one_associations.has_key?(meth) # TODO detect false positives changes for other associations too
        if @associations[meth].is_a?(Array) && @associations[meth][0] == value \
           || @associations[meth] == value #\
          return value
        end
      end
      @skip = true
      send("#{meth}_will_change!")
      @skip = false
      if value.is_a?(Ooor::Base) || value.is_a?(Array) && !value.empty? && value.all? {|i| i.is_a?(Ooor::Base)}
        @loaded_associations[meth] = value
      else
        @loaded_associations.delete(meth)
      end
      @associations[meth] = value
    end

#    # Raise NoMethodError if the named attribute does not exist in order to preserve behavior expected by #clone.
#    def attribute(name)
#      key = name.to_s
#      if self.class.fields.has_key?(key) #TODO check not symbols
#        get_attribute(key)
#      elsif self.class.associations_keys.index(key)
#        get_association(key)
#      else
#        raise NoMethodError
#      end
#    end

    def method_missing(method_symbol, *arguments)
      self.class.reload_fields_definition(false)
      if id
        rpc_execute(method_symbol, [id], *arguments) #we assume that's an action
      else
        super
      end
    rescue UnknownAttributeOrAssociationError => e
      e.klass = self.class
      raise e
    end

  end
end
