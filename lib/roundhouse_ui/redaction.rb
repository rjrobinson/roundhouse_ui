module RoundhouseUi
  # Masks sensitive values when displaying job arguments. Configure the key
  # patterns to redact (matched case-insensitively as substrings):
  #
  #   RoundhouseUi.redact_args = %w[password token secret api_key authorization]
  #
  # Walks arrays/hashes so nested keyword args are covered. No-op by default.
  module Redaction
    MASK = "«redacted»".freeze

    module_function

    def apply(value, patterns = RoundhouseUi.redact_args)
      return value if patterns.nil? || patterns.empty?

      case value
      when Hash
        value.each_with_object({}) do |(k, v), out|
          out[k] = sensitive?(k, patterns) ? MASK : apply(v, patterns)
        end
      when Array
        value.map { |e| apply(e, patterns) }
      else
        value
      end
    end

    def sensitive?(key, patterns)
      key = key.to_s.downcase
      patterns.any? { |p| key.include?(p.to_s.downcase) }
    end
  end
end
