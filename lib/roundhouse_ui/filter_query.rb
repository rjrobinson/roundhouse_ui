# frozen_string_literal: true

module RoundhouseUi
  # One search box, parsed into the exact filters the scan already understands.
  #
  #   class=Billing::SyncWorker error=Timeout::Error stripe
  #
  # `key=value` tokens become structured, EXACT filters; whatever follows them is
  # one verbatim substring needle. That is the whole point: the box becomes the
  # single visible, editable, shareable home for filter state, without a class name
  # in it silently widening the "delete all matching" button below it.
  #
  # Two rules do the work:
  #
  #   1. Split on the FIRST `=` only. Colons are never a delimiter, so
  #      `Billing::SyncWorker` and `Timeout::Error` need no escaping — which is why
  #      the separator is `=` and not Datadog's `:`. Ruby names are colon-dense.
  #   2. Facets lead. Parsing walks from index 0; the first position where a facet
  #      cannot be read ends the facet region, and everything from that byte to the
  #      end is the text needle, as one contiguous slice. With no facets the slice
  #      starts at 0, so `text` is byte-identical to the old `params[:q].strip`,
  #      interior double spaces included. That is not a special case — it falls out
  #      of the rule, which is what keeps parse/to_s compositional.
  #
  # Everything invalid is REFUSED, whole. Never "ignore the token I did not
  # understand": discarding is the only resolution that can select MORE than what
  # was typed, and this feeds a destructive action. `clas=Foo` becoming a substring
  # search for the literal text "clas=Foo" would find nothing and read as "no such
  # jobs exist"; worse, dropping it entirely would widen a delete.
  class FilterQuery
    KEYS = %w[class error queue tag text].freeze

    # Checked before any comparison runs, the same ordering as
    # RoundhouseUi.job_class: a length test first, so a pathological input is
    # bounded before anything walks it. Regexp.timeout is Ruby 3.2+ and the
    # gemspec floor is 3.1, so bounding the input is the only portable defence.
    MAX_LENGTH = 500
    # No facet count cap, deliberately. There are five keys and a conflicting
    # duplicate is refused, so the maximum number of facets in any accepted query
    # is five. A cap of eight was written, could never fire, and its test was
    # actually exercising the duplicate rule — a bound that cannot be reached
    # reads as a risk that does not exist. MAX_LENGTH bounds the total work.
    # Same bound as RoundhouseUi::MAX_JOB_CLASS_NAME, written out because this file
    # is required before that constant is defined — the entry point's require block
    # runs above its own module body.
    MAX_VALUE  = 200

    # Things a Datadog-trained operator will type. Refused BY NAME rather than
    # matched literally: entry_selected? is a pure conjunction, which is exactly
    # what makes a stray token harmless, and every one of these is disjunction or
    # a substring in a facet's clothing.
    # Refused by name, because a Datadog-trained operator will type them and a
    # literal match reads as "no such jobs exist". Narrow on purpose: only a
    # NEGATED KNOWN FACET is unambiguous. A bare "-1" or "*" or "OR" in free text
    # is legitimate text — an error message can contain any of them — and refusing
    # those would break searching for what is actually in the data.
    UNSUPPORTED = [
      [ /\A-(?:#{KEYS.join('|')})=/,
        "Negation is not supported. Every filter narrows; none excludes." ]
    ].freeze

    attr_reader :klass, :error, :queue, :tag, :text, :raw, :message

    class << self
      # Never raises. A refusal is a value, not an exception, because this runs in a
      # before_action on every page including the ones that only browse.
      def parse(raw)
        return refused(raw, "Search is not a single value.") unless raw.nil? || raw.is_a?(String)

        str = raw.to_s
        # Encoding first, then length, then anything that inspects characters.
        # String#strip raises Encoding::CompatibilityError on invalid bytes, so
        # checking validity third meant a malformed query crashed the page instead
        # of being refused — the same ordering trap RoundhouseUi.job_class avoids by
        # testing length before it matches.
        return refused("", "That search contains invalid characters.") unless str.valid_encoding?
        return refused(str, "That search is too long (#{str.length} characters, limit #{MAX_LENGTH}).") if str.length > MAX_LENGTH
        return none if str.strip.empty?

        Parser.new(str).call
      end

      def build(klass: nil, error: nil, queue: nil, tag: nil, text: nil)
        new(klass: klass, error: error, queue: queue, tag: tag, text: text.to_s)
      end

      def none = @none ||= build.freeze

      def refused(raw, message)
        q = build
        q.instance_variable_set(:@raw, raw.to_s)
        q.instance_variable_set(:@message, message)
        q.freeze
      end
    end

    def initialize(klass: nil, error: nil, queue: nil, tag: nil, text: "", raw: nil)
      @klass = presence(klass)
      @error = presence(error)
      @queue = presence(queue)
      @tag   = tag
      @text  = text.to_s
      @raw   = raw || to_s
      @message = nil
    end

    def invalid? = !@message.nil?
    def any_facets? = !(klass.nil? && error.nil? && queue.nil? && tag.nil?)
    def any? = any_facets? || !text.empty?

    # The tag filter's existing two-element shape, so entry_tagged? is untouched.
    def tag_pair
      return nil if tag.nil?

      key, value = tag.split(":", 2)
      return nil if key.to_s.empty? || value.to_s.empty?

      [ key, value ]
    end

    # Canonical, and round-trips: parse(q.to_s) == q. Facets in KEYS order so the
    # box does not reshuffle itself when you press Enter.
    def to_s
      @canonical ||= begin
        parts = []
        parts << "class=#{quoted(klass)}" if klass
        parts << "error=#{quoted(error)}" if error
        parts << "queue=#{quoted(queue)}" if queue
        parts << "tag=#{quoted(tag)}"     if tag
        parts << serialized_text unless text.empty?
        parts.join(" ")
      end
    end
    alias to_param to_s

    def chips
      [ [ :class, klass ], [ :error, error ], [ :queue, queue ], [ :tag, tag ] ]
        .select { |_k, v| v }
    end

    def merge(**over)
      self.class.build(
        klass: over.key?(:klass) ? over[:klass] : klass,
        error: over.key?(:error) ? over[:error] : error,
        queue: over.key?(:queue) ? over[:queue] : queue,
        tag:   over.key?(:tag)   ? over[:tag]   : tag,
        text:  over.key?(:text)  ? over[:text].to_s : text
      )
    end

    def without(*keys)
      over = keys.to_h { |k| [ k, k == :text ? "" : nil ] }
      merge(**over)
    end

    def ==(other) = other.is_a?(FilterQuery) && to_s == other.to_s && invalid? == other.invalid?
    alias eql? ==
    def hash = [ self.class, to_s, invalid? ].hash

    private

    def presence(v)
      s = v.to_s.strip
      s.empty? ? nil : s
    end

    # A value needs quoting when it holds whitespace, or the box would reparse it
    # as a facet boundary and the next Enter would mean something different.
    def quoted(value)
      value.match?(/\s/) ? %("#{value}") : value
    end

    # Text whose first token looks like `key=` has to go back out through the
    # `text=` escape hatch, or re-parsing it would read that token as a facet —
    # and since the key would be an unknown one, refuse the whole query. Pressing
    # Enter twice would then mean something different from pressing it once.
    #
    # Always representable, and worth knowing why: text can only BEGIN with a
    # facet-shaped token if it arrived as text="…" in the first place (a known key
    # would have been parsed as a facet, an unknown one refused), and a quoted
    # value cannot contain a quote, because reading one stops at the first closing
    # quote. So there is no text needing the wrapper that also breaks it.
    def serialized_text
      text.match?(/\A[a-z][a-z0-9_]*=/) ? %(text="#{text}") : text
    end

    # An index walk. No regex over the input, so there is nothing to backtrack.
    class Parser
      def initialize(str)
        @s = str
        @i = 0
        @seen = {}
      end

      def call
        loop do
          skip_space
          break if @i >= @s.length

          key = read_key
          # An unrecognised key refuses the whole query. Falling through to free
          # text is the one resolution that can select MORE than was typed, and a
          # literal substring search for "clas=Foo" would find nothing and read as
          # "no such jobs exist".
          return refuse(nil) if key == :unknown
          break if key.nil?

          value = read_value
          return refuse("Unclosed quote in #{key}=. Quote both ends, or drop the quotes.") if value == :unterminated
          return refuse(bad_value_message(key, value)) unless value_ok?(value)

          if @seen.key?(key) && @seen[key] != value
            return refuse(%(Two different values for #{key}: "#{@seen[key]}" and "#{value}". Pick one.))
          end

          @seen[key] = value
        end

        residue = @s[@i..].to_s.strip

        # text= is the escape hatch for facet-shaped free text. Having BOTH is two
        # ways of saying the same thing, and picking one would discard the other
        # silently — `text=foo bar` would have kept "foo" and thrown "bar" away.
        if @seen.key?("text") && !residue.empty?
          return refuse(%(Text is given twice: text="#{@seen['text']}" and "#{residue}". ) +
                        %(Quote the whole thing: text="#{@seen['text']} #{residue}"))
        end

        unsupported = unsupported_in(residue)
        return refuse(unsupported) if unsupported

        FilterQuery.new(klass: @seen["class"], error: @seen["error"], queue: @seen["queue"],
                        tag: @seen["tag"], text: @seen.fetch("text", residue), raw: @s)
      end

      private

      def skip_space = (@i += 1 while @i < @s.length && @s[@i].match?(/[ \t\n\r]/))

      # A facet candidate is a lowercase key followed immediately by `=`. Anything
      # else ends the facet region and begins the text — which is why pasting a
      # whole error message like `SSL_connect returned=1 errno=0` is unaffected:
      # `SSL_connect` fails the charset at `S`, so the residue starts at 0.
      def read_key
        start = @i
        return nil unless @i < @s.length && @s[@i].match?(/[a-z]/)

        @i += 1 while @i < @s.length && @s[@i].match?(/[a-z0-9_]/)
        unless @i < @s.length && @s[@i] == "="
          @i = start
          return nil
        end

        key = @s[start...@i]
        unless FilterQuery::KEYS.include?(key)
          @i = start
          @unknown = key
          return :unknown
        end

        @i += 1
        key
      end

      def read_value
        if @s[@i] == '"'
          close = @s.index('"', @i + 1)
          return :unterminated if close.nil?

          value = @s[(@i + 1)...close]
          @i = close + 1
          return :unterminated unless @i >= @s.length || @s[@i].match?(/[ \t\n\r]/)

          value
        else
          start = @i
          @i += 1 while @i < @s.length && !@s[@i].match?(/[ \t\n\r]/)
          @s[start...@i]
        end
      end

      def value_ok?(value)
        v = value.to_s.strip
        return false if v.empty? || v.length > FilterQuery::MAX_VALUE
        return false if v.match?(/["\x00-\x1f]/)
        # A wildcard in a facet value is a substring filter wearing a facet's
        # clothing. Facets are exact precisely so they can scope a delete; a
        # glob here would feed bulk_apply the thing this file forbids twice over.
        return false if v.match?(/[*?]/)

        true
      end

      def bad_value_message(key, value)
        v = value.to_s
        return "#{key}= needs a value. To search for the text instead: text=\"#{key}=\"" if v.strip.empty?
        return "That #{key} filter is too long (limit #{FilterQuery::MAX_VALUE})." if v.length > FilterQuery::MAX_VALUE
        if v.match?(/[*?]/)
          return "Wildcards are not supported in #{key}=. Filters match exactly; " \
                 "put the pattern in free text for a substring match."
        end

        "That #{key} filter contains invalid characters."
      end

      def unsupported_in(text)
        text.split(/[ \t\n\r]+/).each do |token|
          FilterQuery::UNSUPPORTED.each do |pattern, why|
            return "#{why} (#{token})" if token.match?(pattern)
          end
        end
        nil
      end

      def refuse(message)
        if @unknown
          message = %(Unknown filter "#{@unknown}". Known filters: #{FilterQuery::KEYS.join(', ')}. ) +
                    %(To search for it as text: text="#{@unknown}=…")
        end
        FilterQuery.refused(@s, message)
      end
    end
  end
end
