# frozen_string_literal: true

module RubyLLM
  module InfiniteContext
    # Active Record Encryption on the text columns of the memory tables:
    # ric_entries.text (the original messages) and ric_nodes.text (the
    # summary lines). The other columns hold numbers, kinds, labels and the
    # tree key, not message text; ric_views.parts holds only [level, i]
    # pairs. Keep the tree key an opaque id (a record id, not a phone number
    # or an email address): it is not encrypted, because the gem finds trees
    # by key.
    #
    #   # config/initializers/infinite_context.rb
    #   RubyLLM::InfiniteContext.encrypt_text = true
    #
    # The encryption is non-deterministic (the Rails default). The gem never
    # searches or filters on these columns in SQL: it reads them by id and
    # works on the text in Ruby, so nothing breaks.
    #
    # Order rule: set it before the app writes a memory row, in an
    # initializer or at boot. It works whether the models are loaded before
    # or after the setting (the gem's models are plain classes, not reloaded
    # by Zeitwerk). Once on, it stays on for the process: setting it to false
    # after it was true raises Error (even before the models load).
    module Encryption
      COLUMNS = {"Entry" => :text, "Node" => :text}.freeze

      module_function

      # Declares `encrypts` on every loaded model that does not have it yet.
      # Safe to call more than once.
      def apply!
        return unless InfiniteContext.encrypt_text?

        each_model do |model, column|
          next if declared?(model, column)

          model.encrypts column
        end
      end

      # True when a loaded gem model encrypts its text column.
      def applied?
        found = false
        each_model { |model, column| found ||= declared?(model, column) }
        found
      end

      def declared?(model, column)
        Array(model.encrypted_attributes).include?(column)
      end

      def each_model
        COLUMNS.each do |name, column|
          next unless InfiniteContext.const_defined?(name, false)

          model = InfiniteContext.const_get(name, false)
          yield model, column if model.respond_to?(:encrypts)
        end
      end
    end

    class << self
      def encrypt_text? = @encrypt_text == true

      # Turns Active Record Encryption on for the gem's text columns. See
      # Encryption for the order rule. Needs Active Record Encryption keys
      # (bin/rails db:encryption:init); without them the first write raises.
      def encrypt_text=(value)
        on = value ? true : false
        if !on && (@encrypt_text == true || Encryption.applied?)
          raise Error, "encrypt_text cannot be turned off once it is on (restart the process)"
        end

        @encrypt_text = on
        Encryption.apply!
      end
    end
  end
end
