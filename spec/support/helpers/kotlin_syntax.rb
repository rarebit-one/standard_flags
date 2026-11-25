# A lightweight syntax check for the Kotlin standard_flags:kotlin writes,
# for CI without kotlinc: it tokenizes the file (comments, string literals
# and their escapes, identifiers, numbers, punctuation) and parses exactly
# the subset the generator emits (a package line, `object` with `const val`s,
# and enum classes with entries, annotations and a companion object of
# one-line functions). Anything else is an error. The kotlinc example in
# spec/standard_flags/tooling_kotlin_spec.rb compiles the same output when
# a compiler is available.
module KotlinSyntax
  class Error < StandardError; end

  KEYWORDS = %w[as break class continue do else false for fun if in interface is null object package return super
                this throw true try typealias typeof val var when while].freeze
  ESCAPES = %w[t b n r ' " \\ $].freeze

  Token = Struct.new(:type, :text, :line)

  module_function

  def check!(source)
    Parser.new(tokenize(source)).file
    true
  end

  def tokenize(source)
    tokens = []
    i = 0
    line = 1
    while i < source.length
      char = source[i]
      if char == "\n"
        line += 1
        i += 1
      elsif char.match?(/[ \t]/)
        i += 1
      elsif source[i, 2] == "//"
        i = source.index("\n", i) || source.length
      elsif source[i, 2] == "/*"
        close = source.index("*/", i + 2) or raise Error, "line #{line}: unterminated comment"
        line += source[i...close].count("\n")
        i = close + 2
      elsif char == '"'
        i, text = string(source, i, line)
        tokens << Token.new(:string, text, line)
      elsif char.match?(/[A-Za-z_]/)
        text = source[i..][/\A[A-Za-z_][A-Za-z0-9_]*/]
        tokens << Token.new(KEYWORDS.include?(text) ? :keyword : :ident, text, line)
        i += text.length
      elsif char.match?(/[0-9]/)
        text = source[i..][/\A[0-9]+/]
        tokens << Token.new(:int, text, line)
        i += text.length
      elsif source[i, 2] == "=="
        tokens << Token.new(:punct, "==", line)
        i += 2
      elsif "{}(),:;.=?@".include?(char)
        tokens << Token.new(:punct, char, line)
        i += 1
      else
        raise Error, "line #{line}: unexpected #{char.inspect}"
      end
    end
    tokens
  end

  def string(source, start, line)
    i = start + 1
    out = +""
    loop do
      char = source[i] or raise Error, "line #{line}: unterminated string"
      raise Error, "line #{line}: newline in string" if char == "\n"
      raise Error, "line #{line}: unescaped $ in string" if char == "$"
      return [ i + 1, out ] if char == '"'

      if char == "\\"
        escape = source[i + 1]
        if escape == "u"
          raise Error, "line #{line}: bad \\u escape" unless source[i + 2, 4].to_s.match?(/\A\h{4}\z/)

          out << source[i, 6]
          i += 6
        else
          raise Error, "line #{line}: bad escape \\#{escape}" unless ESCAPES.include?(escape)

          out << source[i, 2]
          i += 2
        end
      else
        out << char
        i += 1
      end
    end
  end

  class Parser
    def initialize(tokens)
      @tokens = tokens
      @at = 0
    end

    def file
      if peek?("package")
        take("package")
        qualified_name
      end
      declaration until done?
    end

    private

    def declaration
      if peek?("object") then object
      elsif peek?("enum") then enum
      else fail_at("expected object or enum class")
      end
    end

    def object
      take("object")
      ident
      take("{")
      until peek?("}")
        take("const")
        take("val")
        ident
        take(":")
        type
        take("=")
        literal = advance
        fail_at("expected a literal", literal) unless %i[int string].include?(literal&.type)
      end
      take("}")
    end

    def enum
      take("enum")
      take("class")
      ident
      parameters if peek?("(")
      take("{")
      entries
      if peek?(";")
        take(";")
        companion if peek?("companion")
      end
      take("}")
    end

    def parameters
      take("(")
      loop do
        take("val")
        ident
        take(":")
        type
        break unless peek?(",")

        take(",")
      end
      take(")")
    end

    def entries
      until peek?(";") || peek?("}")
        annotation while peek?("@")
        ident
        arguments if peek?("(")
        break unless peek?(",")

        take(",")
      end
    end

    def annotation
      take("@")
      ident
      take("(")
      expect_type(:string)
      take(")")
    end

    def arguments
      take("(")
      loop do
        if peek_type?(:string)
          advance
        else
          ident
          take(".")
          ident
        end
        break unless peek?(",")

        take(",")
      end
      take(")")
    end

    def companion
      take("companion")
      take("object")
      take("{")
      function until peek?("}")
      take("}")
    end

    # fun name(arg: Type): Type = values().firstOrNull { it.field == arg }
    def function
      take("fun")
      ident
      take("(")
      ident
      take(":")
      type
      take(")")
      take(":")
      type
      take("=")
      ident
      take("(")
      take(")")
      take(".")
      ident
      take("{")
      ident
      take(".")
      ident
      take("==")
      ident
      take("}")
    end

    def type
      ident
      take("?") if peek?("?")
    end

    def qualified_name
      ident
      while peek?(".")
        take(".")
        ident
      end
    end

    def ident
      token = advance
      fail_at("expected an identifier", token) unless token&.type == :ident
      token.text
    end

    def expect_type(type)
      token = advance
      fail_at("expected #{type}", token) unless token&.type == type
    end

    def take(text)
      token = advance
      fail_at("expected #{text.inspect}", token) unless token && token.type != :string && token.text == text
    end

    def peek?(text)
      token = @tokens[@at]
      !token.nil? && token.type != :string && token.text == text
    end

    def peek_type?(type)
      @tokens[@at]&.type == type
    end

    def advance
      token = @tokens[@at]
      @at += 1
      token
    end

    def done?
      @at >= @tokens.length
    end

    def fail_at(message, token = @tokens[@at])
      where = token ? "line #{token.line} at #{token.text.inspect}" : "end of file"
      raise Error, "#{where}: #{message}"
    end
  end
end
