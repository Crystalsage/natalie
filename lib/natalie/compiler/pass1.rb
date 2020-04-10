module Natalie
  class Compiler
    # process S-expressions from Ruby to C
    class Pass1 < SexpProcessor
      def initialize(compiler_context)
        super()
        self.require_empty = false
        @compiler_context = compiler_context
      end

      def go(ast)
        process(ast)
      end

      def process_alias(exp)
        (_, (_, new_name), (_, old_name)) = exp
        exp.new(:block,
          s(:nat_alias, :env, :self, s(:s, new_name), s(:s, old_name)),
          s(:nil))
      end

      def process_and(exp)
        (_, lhs, rhs) = exp
        lhs = process(lhs)
        rhs = process(rhs)
        exp.new(:c_if, s(:nat_truthy, lhs), rhs, lhs)
      end

      def process_array(exp)
        (_, *items) = exp
        arr = temp('arr')
        items = items.map do |item|
          if item.sexp_type == :splat
            s(:nat_array_push_splat, :env, arr, process(item.last))
          else
            s(:nat_array_push, :env, arr, process(item))
          end
        end
        exp.new(:block,
          s(:declare, arr, s(:nat_array, :env)),
          *items.compact,
          arr)
      end

      def process_attrasgn(exp)
        (_, receiver, method, *args) = exp
        if args.any? { |a| a.sexp_type == :splat }
          args = s(:args_array, process(s(:array, *args.map { |n| process(n) })))
        else
          args = s(:args, *args.map { |n| process(n) })
        end
        exp.new(:nat_send, process(receiver), method, args)
      end

      def process_block(exp)
        (_, *parts) = exp
        exp.new(:block, *parts.map { |p| p.is_a?(Sexp) ? process(p) : p })
      end

      def process_break(exp)
        (_, value) = exp
        value ||= s(:nil)
        break_name = temp('break_value')
        exp.new(:block,
          s(:declare, break_name, process(value)),
          s(:nat_flag_break, break_name),
          s(:c_return, break_name))
      end

      def process_call(exp, is_super: false)
        (_, receiver, method, *args) = exp
        (_, block_pass) = args.pop if args.last&.sexp_type == :block_pass
        if args.any? { |a| a.sexp_type == :splat }
          args = s(:args_array, process(s(:array, *args.map { |n| process(n) })))
        else
          args = s(:args, *args.map { |a| process(a) })
        end
        receiver = receiver ? process(receiver) : :self
        call = if is_super
                 exp.new(:nat_super, args)
               else
                 exp.new(:nat_send, receiver, method, args)
               end
        if block_pass
          proc_name = temp('proc_to_block')
          call << "#{proc_name}->block"
          exp.new(:block,
            s(:declare, proc_name, process(block_pass)),
            call)
        else
          call << 'NULL'
          call
        end
      end

      def process_case(exp)
        (_, value, *whens, else_body) = exp
        value_name = temp('case_value')
        cond = s(:cond)
        whens.each do |when_exp|
          (_, (_, *matchers), *when_body) = when_exp
          when_body = when_body.map { |w| process(w) }
          when_body = [s(:nil)] if when_body == [nil]
          matchers.each do |matcher|
            cond << s(:nat_truthy, s(:nat_send, process(matcher), '===', s(:args, value_name), 'NULL'))
            cond << s(:block, *when_body)
          end
        end
        cond << s(:else)
        cond << process(else_body || s(:nil))
        exp.new(:block,
          s(:declare, value_name, process(value)),
          cond)
      end

      def process_cdecl(exp)
        (_, name, value) = exp
        exp.new(:nat_const_set, :env, :self, s(:s, name), process(value))
      end

      def process_class(exp)
        (_, name, superclass, *body) = exp
        superclass ||= s(:const, 'Object')
        fn = temp('class_body')
        klass = temp('class')
        exp.new(:block,
          s(:class_fn, fn, process(s(:block, *body))),
          s(:declare, klass, s(:nat_const_get_or_null, :env, :self, s(:s, name))),
          s(:c_if, s(:not, klass),
            s(:block,
              s(:set, klass, s(:nat_subclass, :env, process(superclass), s(:s, name))),
              s(:nat_const_set, :env, :self, s(:s, name), klass))),
          s(:nat_call, fn, "&#{klass}->env", klass))
      end

      def process_colon2(exp)
        (_, parent, name) = exp
        parent_name = temp('parent')
        exp.new(:block,
          s(:declare, parent_name, process(parent)),
          s(:nat_const_get, :env, parent_name, s(:s, name)))
      end

      def process_const(exp)
        (_, name) = exp
        exp.new(:nat_const_get, :env, :self, s(:s, name))
      end

      def process_cvdecl(exp)
        (_, name, value) = exp
        exp.new(:nat_cvar_set, :env, :self, s(:s, name), process(value))
      end

      def process_cvasgn(exp)
        (_, name, value) = exp
        exp.new(:nat_cvar_set, :env, :self, s(:s, name), process(value))
      end

      def process_cvar(exp)
        (_, name) = exp
        exp.new(:nat_cvar_get, :env, :self, s(:s, name))
      end

      def process_defined(exp)
        (_, name) = exp
        name = process(name) if name.sexp_type == :call
        exp.new(:defined, name)
      end

      def process_defn_internal(exp)
        (_, name, (_, *args), *body) = exp
        name = name.to_s
        fn_name = temp('fn')
        if args.last&.to_s&.start_with?('&')
          block_arg = exp.new(:nat_var_set, :env, s(:s, args.pop.to_s[1..-1]), s(:nat_proc, :env, 'block'))
        end
        args_name = temp('args_as_array')
        assign_args = s(:block,
                        s(:declare, args_name, s(:nat_args_to_array, :env, s(:l, 'argc'), s(:l, 'args'))),
                        *prepare_args(args, args_name))
        method_body = process(s(:block, *body))
        if raises_local_jump_error?(method_body)
          # We only need to wrap method body in a rescue for LocalJumpError if there is a `return` inside a block.
          method_body = s(:nat_rescue,
            method_body,
            s(:cond,
              s(:is_a, 'env->exception', process(s(:const, :LocalJumpError))),
              process(s(:call, s(:l, 'env->exception'), :exit_value)),
              s(:else),
              s(:nat_raise_exception, :env, 'env->exception')))
        end
        exp.new(:def_fn, fn_name,
          s(:block,
            s(:nat_env_set_method_name, name),
            assign_args,
            block_arg || s(:block),
            method_body))
      end

      def process_defn(exp)
        (_, name, args, *body) = exp
        fn = process_defn_internal(exp)
        exp.new(:block,
          fn,
          s(:nat_define_method, :env, :self, s(:s, name), fn[1]),
          s(:nat_symbol, :env, s(:s, name)))
      end

      def process_defs(exp)
        (_, owner, name, args, *body) = exp
        fn = process_defn_internal(exp.new(:defs, name, args, *body))
        exp.new(:block,
          fn,
          s(:nat_define_singleton_method, :env, process(owner), s(:s, name), fn[1]),
          s(:nat_symbol, :env, s(:s, name)))
      end

      def process_dot2(exp)
        (_, beginning, ending) = exp
        exp.new(:nat_range, :env, process(beginning), process(ending), 0)
      end

      def process_dot3(exp)
        (_, beginning, ending) = exp
        exp.new(:nat_range, :env, process(beginning), process(ending), 1)
      end

      def process_dstr(exp)
        (_, start, *rest) = exp
        string = temp('string')
        segments = rest.map do |segment|
          case segment.sexp_type
          when :evstr
            s(:nat_string_append_nat_string, :env, string, process(s(:call, segment.last, :to_s)))
          when :str
            s(:nat_string_append, :env, string, s(:s, segment.last))
          else
            raise "unknown dstr segment: #{segment.inspect}"
          end
        end
        exp.new(:block,
          s(:declare, string, s(:nat_string, :env, s(:s, start))),
          *segments,
          string)
      end

      def process_gasgn(exp)
        (_, name, value) = exp
        exp.new(:nat_global_set, :env, s(:s, name), process(value))
      end

      def process_gvar(exp)
        (_, name) = exp
        exp.new(:nat_global_get, :env, s(:s, name))
      end

      def process_hash(exp)
        (_, *pairs) = exp
        hash = temp('hash')
        inserts = pairs.each_slice(2).map do |(key, val)|
          s(:nat_hash_put, :env, hash, process(key), process(val))
        end
        exp.new(:block,
          s(:declare, hash, s(:nat_hash, :env)),
          s(:block, *inserts),
          hash)
      end

      def process_if(exp)
        (_, condition, true_body, false_body) = exp
        condition = exp.new(:nat_truthy, process(condition))
        exp.new(:c_if,
          condition,
          process(true_body || s(:nil)),
          process(false_body || s(:nil)))
      end

      def process_iasgn(exp)
        (_, name, value) = exp
        exp.new(:nat_ivar_set, :env, :self, s(:s, name), process(value))
      end

      def process_iter(exp)
        (_, call, (_, *args), *body) = exp
        if args.last&.to_s&.start_with?('&')
          block_arg = exp.new(:nat_arg_set, :env, s(:s, args.pop.to_s[1..-1]), s(:nat_proc, :env, 'block'))
        end
        block_fn = temp('block_fn')
        block = block_fn.sub(/_fn/, '')
        call = process(call)
        call[call.size-1] = block
        args_name = temp('args_as_array')
        assign_args = s(:block,
                        s(:declare, args_name, s(:nat_block_args_to_array, :env, args.size, s(:l, 'argc'), s(:l, 'args'))),
                        *prepare_args(args, args_name))
        exp.new(:block,
          s(:block_fn, block_fn,
            s(:block,
              s(:nat_env_set_method_name, '<block>'),
              assign_args,
              block_arg || s(:block),
              process(s(:block, *body)))),
          s(:declare_block, block, s(:nat_block, :env, :self, block_fn)),
          call)
      end

      def process_ivar(exp)
        (_, name) = exp
        exp.new(:nat_ivar_get, :env, :self, s(:s, name))
      end

      def process_lambda(exp)
        exp.new(:nat_lambda, :env, 'NULL') # note: the block gets overwritten by process_iter later
      end

      def process_lasgn(exp)
        (_, name, val) = exp
        exp.new(:nat_var_set, :env, s(:s, name), process(val))
      end

      def process_lit(exp)
        lit = exp.last
        case lit
        when Integer
          exp.new(:nat_integer, :env, lit)
        when Range
          exp.new(:nat_range, :env, process_lit(s(:lit, lit.first)), process_lit(s(:lit, lit.last)), lit.exclude_end? ? 1 : 0)
        when Regexp
          exp.new(:nat_regexp, :env, s(:s, lit.inspect[1...-1]))
        when Symbol
          exp.new(:nat_symbol, :env, s(:s, lit))
        else
          raise "unknown lit: #{exp.inspect}"
        end
      end

      def process_lvar(exp)
        (_, name) = exp
        exp.new(:nat_var_get, :env, s(:s, name))
      end
      
      def process_masgn(exp)
        (_, names, val) = exp
        names = names[1..-1]
        val = val.last if val.sexp_type == :to_ary
        value_name = temp('masgn_value')
        s(:block,
          s(:declare, value_name, s(:nat_to_ary, :env, process(val), s(:l, :false))),
          *prepare_masgn(exp, value_name))
      end

      def prepare_masgn(exp, value_name)
        prepare_masgn_paths(exp).map do |name, path_details|
          path = path_details[:path]
          if name.is_a?(Sexp)
            if name.sexp_type == :splat
              value = s(:nat_array_value_by_path, :env, value_name, s(:nil), s(:l, :true), path_details[:offset_from_end], path.size, *path)
              prepare_masgn_set(name.last, value)
            else
              default_value = name.size == 3 ? process(name.pop) : s(:nil)
              value = s(:nat_array_value_by_path, :env, value_name, default_value, s(:l, :false), 0, path.size, *path)
              prepare_masgn_set(name, value)
            end
          else
            raise "unknown masgn type: #{name.inspect}"
          end
        end
      end

      def prepare_args(names, value_name)
        names = prepare_arg_names(names)
        args_have_default = names.map { |e| %i[iasgn lasgn].include?(e.sexp_type) && e.size == 3 }
        defaults = args_have_default.select { |d| d }
        defaults_on_right = defaults.any? && args_have_default.uniq == [false, true]
        prepare_masgn_paths(s(:masgn, s(:array, *names))).map do |name, path_details|
          path = path_details[:path]
          if name.is_a?(Sexp)
            if name.sexp_type == :splat
              value = s(:nat_arg_value_by_path, :env, value_name, s(:nil), s(:l, :true), names.size, defaults.size, defaults_on_right ? s(:l, :true) : s(:l, :false), path_details[:offset_from_end], path.size, *path)
              prepare_masgn_set(name.last, value, arg: true)
            else
              default_value = name.size == 3 ? process(name.pop) : s(:nil)
              value = s(:nat_arg_value_by_path, :env, value_name, default_value, s(:l, :false), names.size, defaults.size, defaults_on_right ? s(:l, :true) : s(:l, :false), 0, path.size, *path)
              prepare_masgn_set(name, value, arg: true)
            end
          else
            raise "unknown masgn type: #{name.inspect}"
          end
        end
      end

      def prepare_arg_names(names)
        names.map do |name|
          case name
          when Symbol
            case name.to_s
            when /^\*@(.+)/
              s(:splat, s(:iasgn, name[1..-1].to_sym))
            when /^\*(.+)/
              s(:splat, s(:lasgn, name[1..-1].to_sym))
            when /^\*/
              s(:splat, s(:lasgn, :_))
            when /^@/
              s(:iasgn, name)
            else
              s(:lasgn, name)
            end
          when Sexp
            case name.sexp_type
            when :lasgn
              name
            when :masgn
              s(:masgn, s(:array, *prepare_arg_names(name[1..-1])))
            else
              raise "unknown arg type: #{name.inspect}"
            end
          when nil
            s(:lasgn, :_)
          else
            raise "unknown arg type: #{name.inspect}"
          end
        end
      end

      def prepare_masgn_set(exp, value, arg: false)
        case exp.sexp_type
        when :cdecl
          s(:nat_const_set, :env, :self, s(:s, exp.last), value)
        when :gasgn
          s(:nat_global_set, :env, s(:s, exp.last), value)
        when :iasgn
          s(:nat_ivar_set, :env, :self, s(:s, exp.last), value)
        when :lasgn
          if arg
            s(:nat_arg_set, :env, s(:s, exp.last), value)
          else
            s(:nat_var_set, :env, s(:s, exp.last), value)
          end
        else
          raise "unknown masgn type: #{exp.inspect}"
        end
      end

      # Ruby blows the stack at around this number, so let's limit Natalie as well.
      # Anything over a few dozen is pretty crazy, actually.
      MAX_MASGN_PATH_INDEX = 131_044

      def prepare_masgn_paths(exp, prefix = [])
        (_, (_, *names)) = exp
        splatted = false
        names.each_with_index.each_with_object({}) do |(e, index), hash|
          raise 'destructuring assignment is too big' if index > MAX_MASGN_PATH_INDEX
          has_default = %i[iasgn lasgn].include?(e.sexp_type) && e.size == 3
          if e.is_a?(Sexp) && e.sexp_type == :masgn
            hash.merge!(prepare_masgn_paths(e, prefix + [index]))
          elsif e.sexp_type == :splat
            splatted = true
            hash[e] = { path: prefix + [index], offset_from_end: names.size - index - 1 }
          elsif splatted
            hash[e] = { path: prefix + [(names.size - index) * -1] }
          else
            hash[e] = { path: prefix + [index] }
          end
        end
      end

      def process_match2(exp)
        (_, regexp, string) = exp
        s(:nat_send, process(regexp), "=~", s(:args, process(string)))
      end

      def process_match3(exp)
        (_, string, regexp) = exp
        s(:nat_send, process(regexp), "=~", s(:args, process(string)))
      end

      def process_module(exp)
        (_, name, *body) = exp
        fn = temp('module_body')
        mod = temp('module')
        exp.new(:block,
          s(:module_fn, fn, process(s(:block, *body))),
          s(:declare, mod, s(:nat_const_get_or_null, :env, :self, s(:s, name))),
          s(:c_if, s(:not, mod),
            s(:block,
              s(:set, mod, s(:nat_module, :env, s(:s, name))),
              s(:nat_const_set, :env, :self, s(:s, name), mod))),
          s(:nat_call, fn, "&#{mod}->env", mod))
      end

      def process_next(exp)
        (_, value) = exp
        value ||= s(:nil)
        s(:c_return, process(value))
      end

      def process_op_asgn_or(exp)
        (_, (var_type, name), value) = exp
        case var_type
        when :cvar
          result_name = temp('cvar')
          exp.new(:block,
            s(:declare, result_name, s(:nat_cvar_get_or_null, :env, :self, s(:s, name))),
            s(:c_if, s(:nat_truthy, result_name), result_name, process(value)))
        when :gvar
          result_name = temp('gvar')
          exp.new(:block,
            s(:declare, result_name, s(:nat_global_get, :env, s(:s, name))),
            s(:c_if, s(:nat_truthy, result_name), result_name, process(value)))
        when :ivar
          result_name = temp('ivar')
          exp.new(:block,
            s(:declare, result_name, s(:nat_ivar_get, :env, :self, s(:s, name))),
            s(:c_if, s(:nat_truthy, result_name), result_name, process(value)))
        when :lvar
          var = process(s(:lvar, name))
          exp.new(:block,
            s(:nat_var_declare, :env, s(:s, name)),
            s(:c_if, s(:defined, s(:lvar, name)),
              s(:c_if, s(:nat_truthy, var),
                var,
                process(value))))
        else
          raise "unknown op_asgn_or type: #{var_type.inspect}"
        end
      end

      def process_or(exp)
        (_, lhs, rhs) = exp
        lhs = process(lhs)
        rhs = process(rhs)
        exp.new(:c_if, s(:not, s(:nat_truthy, lhs)), rhs, lhs)
      end

      def process_rescue(exp)
        (_, *rest) = exp
        else_body = rest.pop if rest.last.sexp_type != :resbody
        (body, resbodies) = rest.partition { |n| n.first != :resbody }
        begin_fn = temp('begin_fn')
        rescue_fn = begin_fn.sub(/begin/, 'rescue')
        rescue_block = s(:cond)
        resbodies.each_with_index do |(_, (_, *match), *resbody), index|
          lasgn = match.pop if match.last&.sexp_type == :lasgn
          match << s(:const, 'StandardError') if match.empty?
          condition = s(:is_a, 'env->exception', *match.map { |n| process(n) })
          rescue_block << condition
          resbody = resbody == [nil] ? [s(:nil)] : resbody.map { |n| process(n) }
          rescue_block << (lasgn ? s(:block, process(lasgn), *resbody) : s(:block, *resbody))
        end
        rescue_block << s(:else)
        rescue_block << s(:block, s(:nat_raise_exception, :env, 'env->exception'))
        if else_body
          body << s(:clear_jump_buf)
          body << else_body
        end
        body = body.empty? ? [s(:nil)] : body
        exp.new(:block,
          s(:begin_fn, begin_fn,
            s(:block,
              s(:nat_rescue,
                s(:block, *body.map { |n| process(n) }),
                rescue_block))),
          s(:nat_call_begin, :env, :self, begin_fn))
      end

      def process_return(exp)
        (_, value) = exp
        enclosing = context.detect { |n| %i[defn defs iter].include?(n) }
        if enclosing == :iter
          exp.new(:nat_raise_local_jump_error, :env, process(value), s(:s, "unexpected return"))
        else
          exp.new(:c_return, process(value))
        end
      end

      def process_sclass(exp)
        (_, obj, *body) = exp
        exp.new(:with_self, s(:nat_singleton_class, :env, process(obj)),
          s(:block, *body))
      end

      def process_str(exp)
        (_, str) = exp
        exp.new(:nat_string, :env, s(:s, str))
      end

      def process_super(exp)
        process_call(exp, is_super: true)
      end

      def process_while(exp)
        (_, condition, body, unknown) = exp
        raise 'check this out' if unknown != true # NOTE: I don't know what this is; it always seems to be true
        body ||= s(:nil)
        exp.new(:block,
          s(:c_while, 'true',
            s(:block,
              s(:c_if, s(:not, s(:nat_truthy, process(condition))), s(:c_break)),
              process(body))),
          s(:nil))
      end

      def process_yield(exp)
        (_, *args) = exp
        if args.any? { |a| a.sexp_type == :splat }
          args = s(:args_array, process(s(:array, *args.map { |n| process(n) })))
        else
          args = s(:args, *args.map { |n| process(n) })
        end
        exp.new(:NAT_RUN_BLOCK_AND_POSSIBLY_BREAK, args)
      end

      def process_zsuper(exp)
        exp.new(:nat_super, s(:args))
      end

      def temp(name)
        n = @compiler_context[:var_num] += 1
        "#{@compiler_context[:var_prefix]}#{name}#{n}"
      end

      def raises_local_jump_error?(exp, my_context: [])
        if exp.is_a?(Sexp)
          case exp.sexp_type
          when :nat_raise_local_jump_error
            return true if my_context.include?(:block_fn)
          when :def_fn # method within a method (unusual, but allowed!)
            return false
          else
            my_context << exp.sexp_type
            return true if exp[1..-1].any? { |e| raises_local_jump_error?(e, my_context: my_context) }
            my_context.pop
          end
        end
        return false
      end
    end
  end
end
