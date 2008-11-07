module Hobo

  module Lifecycles

    module Actions

      def set_or_check_who!(record, user)
        case who
        when :nobody
          user == :nobody
        when :anybody
          true
        when :self
          record == user
        when Array
          who.detect {|attribute| record.send(attribute) == user }
        else
          current = record.send(who)
          # If there is a current value, it must either be the user, or an array containing the user
          # If not, and the type of the attribute matches, set it to be the acting user
          if current.is_a?(Array)
            user.in? current
          elsif current
            user == current
          elsif user.is_a?(record.class.attr_type(who))
            record.send("#{who}=", user)
            true
          else
            false
          end
        end
      end


      def run_hook(record, hook, *args)
        if hook.is_a?(Symbol)
          record.send(hook, *args)
        elsif hook.is_a?(Proc)
          hook.call(record, *args)
        end
      end


      def fire_event(record, event)
        record.instance_eval(&event) if event
      end


      def check_guard(record, user)
        !options[:if] || run_hook(record, options[:if], user)
      end

      def check_invariants(record)
        record.lifecycle.invariants_satisfied?
      end


      def prepare(record, user, attributes=nil)
        if attributes
          attributes = extract_attributes(attributes)
          record.attributes = attributes
        end
        record.lifecycle.generate_key if options[:new_key]
        set_or_check_who!(record, user) && record
      end


      def prepare_and_check!(record, user, attributes=nil)
        prepare(record, user, attributes) && check_guard(record, user) && check_invariants(record)
      end
      
      def publishable?
        who != :nobody
      end

    end

  end
end
