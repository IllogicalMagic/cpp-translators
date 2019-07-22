#!/usr/bin/ruby

require 'optparse'
require 'pp'
require 'set'

options = {}
OptionParser.new do |opts|
  opts.on("-i", "--input FILE", "File with DFA description"){ |v| options[:in] = v }
  opts.on("-o", "--output-dir DIR", "Directory to output generated headers"){ |v| options[:out] = v }
end.parse!

input = options.fetch(:in)
output = options.fetch(:out)

def parse_alphabet(desc_str)
  m = /alphabet=\{\w(,\w)*\}/i.match(desc_str)
  raise "Bad alphabet" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  alphabet = m[1].split(",")
  [alphabet, desc_str]
end

def parse_states(desc_str)
  m = /states=\{\w+(,\w+)*\}/i.match(desc_str)
  raise "Bad states set" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  states = m[1].split(",")
  [states, desc_str]
end

def parse_initial(desc_str)
  m = /initial=\w+/i.match(desc_str)
  raise "Bad initial state" if m.nil?
  desc_str = m.post_match.lstrip
  initial = m[0].split("=")[1]
  [initial, desc_str]
end

def parse_final(desc_str)
  m = /final=\{\w+(,\w+)*\}/i.match(desc_str)
  raise "Bad final states" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  final = m[1].split(",")
  [final, desc_str]
end

class Transition
  attr_reader :cur
  attr_reader :sym
  attr_reader :cond
  attr_reader :next
  attr_reader :action

  def initialize(trans_str)
    m = /\((\w+),((?:\w|\$)?),([zp]?)\)->\((\w+),([id]?)\)/.match(trans_str)
    raise "Incorrect state string: #{trans_str}" if m.nil?
    @cur = m[1]
    @sym = m[2]
    @cond = m[3]
    @next = m[4]
    @action = m[5]
  end

  def to_s
    "(#{@cur},#{@sym},#{@cond})->(#{@next},#{@action})"
  end
end

def parse_transitions(desc_str)
  m = /transitions=\{\(\w+,(\w|\$)?,[zp]?\)->\(\w+,[id]?\)(,\(\w+,(\w|\$)?,[zp]?\)->\(\w+,[id]?\))*\}/.match(desc_str)
  raise "Bad transitions" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  trans = m[1].split(/,(?=\()/)
  trans = trans.map{ |c| Transition.new(c) }
  [trans, desc_str]
end

class Edge
  attr_reader :sym
  attr_reader :cond
  attr_reader :next
  attr_reader :action

  def initialize(sym, cond, nxt, action)
    @sym = sym
    @next = nxt
    case cond
    when ""
      @cond = :any
    when "z"
      @cond = :zero
    when "p"
      @cond = :positive
    end
    case action
    when "i"
      @action = :inc
    when "d"
      @action = :dec
    when ""
      @action = :nop
    end
  end
end

class State
  attr_reader :name
  attr_reader :outgoing
  attr_reader :consume
  attr_reader :final

  def initialize(s, outgoing, consume, final)
    @name = s
    @outgoing = outgoing
    @consume = consume
    @final = final
  end

  def to_s
    props = []
    props << "non-consuming" unless @consume
    props << "final" if @final
    props = props.empty? ? "" : " (#{props.join(', ')})"
    str = "State #{name}#{props}. Transitions:\n"
    @outgoing.each do |e|
      case e.action
      when :inc
        action = ", increment counter"
      when :dec
        action = ", decrement counter"
      when :nop
        action = ""
      end
      case e.cond
      when :zero
        cond = "if zero"
      when :positive
        cond = "if not zero"
      when :any
        cond = "always"
      end
      symbol = e.sym.empty? ? "No symbol" : "Symbol #{e.sym}"
      str += "#{symbol}, #{cond} goto #{e.next}#{action}\n"
    end
    str
  end
end

class CTR
  attr_reader :alphabet
  attr_reader :states
  attr_reader :initial

  def initialize(alphabet, states, initial, final, transitions)
    @alphabet = alphabet
    @initial = initial
    build_states(states, transitions, final)
  end

  private

  def build_states(states, transitions, final)
    alphabet = @alphabet.to_set
    states = states.to_set
    final = final.to_set

    unless states.include?(@initial)
      raise "Initial state #{@initial} doesn't belong to states set"
    end

    final.each do |f|
      unless states.include?(f)
        raise "Final state #{f} doesn't belong to states set"
      end
    end

    transitions.each do |trans|
      unless states.include?(trans.cur)
        raise "Transition #{trans} from unknown state #{trans.cur}"
      end
      unless states.include?(trans.next)
        raise "Transition #{trans} to unknown state #{trans.next}"
      end
      unless trans.sym.empty? or trans.sym == "$" or alphabet.include?(trans.sym)
        raise "Transition #{trans} by unknown symbol #{trans.sym}"
      end
    end

    state_to_next = Hash.new{ |h, k| h[k] = Array.new }
    no_consume = Set.new
    transitions.each do |trans|
      nxt = state_to_next[trans.cur]
      nxt << Edge.new(trans.sym, trans.cond, trans.next, trans.action)
      no_consume.add(trans.next) if trans.sym.empty?
    end

    state_to_next.each do |s, trans|
      if trans.empty? && !final.include?(s)
        raise "Dead end non-final transition #{s}"
      end
    end

    dead_end = states - state_to_next.each_key
    dead_end.each{ |d| state_to_next[d] = [] }

    @states = state_to_next.map do |s, trans|
      State.new(s, trans, !no_consume.include?(s), final.include?(s))
    end
  end
end

def parse_description(desc_str)
  desc_str = desc_str.delete(" \t\r\f\v").tr("\n", " ")
  alphabet, desc_str = parse_alphabet(desc_str)
  states, desc_str = parse_states(desc_str)
  initial, desc_str = parse_initial(desc_str)
  final, desc_str = parse_final(desc_str)
  trans, desc_str = parse_transitions(desc_str)
  [alphabet, states, initial, final, trans]
end

desc_str = ""
File.open(input, "r") do |f|
  desc_str = f.read
end

desc = parse_description(desc_str)
ctr = CTR.new(*desc)

puts ctr.states

Dir.mkdir(output) unless Dir.exist?(output)
Dir.chdir(output)

def generate_header(ctr)
  header = "ctr.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "#define C __COUNTER__\n"
    f << "#define L __LINE__\n"
    f << "#define I __INCLUDE_LEVEL__\n\n"
    f << "/* alphabet */\n"
    logsize = (ctr.alphabet.size - 1).bit_length + 1
    ctr.alphabet.each_with_index do |a, i|
      n = i.to_s(2)
      n = "%0*d" % [logsize - 1, n]
      f << "#define A_#{a} 0b1#{n}\n"
    end
    f << "#define END 0\n"
    f << "#define A_MASK 0b#{((1 << logsize) - 1).to_s(2)}\n"
    f << "#define A_SIZE #{logsize}\n\n"
    
    f << "#define GET_SYM ((INPUT >> ((I - 3) * A_SIZE)) & A_MASK)\n\n"
    f << "#define IS_ZERO 1\n\n"

    f << "/* include initial state */\n"
    f << "#include \"ctr_#{ctr.initial}.h\"\n"
  end
end

def generate_get_sym(ctr)
  header = "get_sym.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    cond = "if"
    ctr.alphabet.each do |a|
      f << "##{cond} GET_SYM == A_#{a}\n"
      f << "  #define CUR_SYM A_#{a}\n"
      cond = "elif"
    end
    f << "#elif GET_SYM == END\n"
    f << "  #define CUR_SYM END\n"
    f << "#endif\n"
  end
end

def generate_action(f, n, sum, ctr_pad_bits, dec)
  f << "#line C\n"
  ctr_pad = 1 << ctr_pad_bits
  line = 0
  cond = "if"
  (1...ctr_pad).each do |c|
    f << "##{cond} ((L - #{line}) & #{ctr_pad - 1}) == #{ctr_pad - c}\n"
    stab = (["C"] * c).join(",")
    f << "  #if #{stab}\n"
    f << "  #endif\n"
    line += 3
    cond = "elif"
  end
  stab = (["C"] * ctr_pad).join(",")
  f << "#else\n"
  f << "  #if #{stab}\n"
  f << "  #endif\n"
  f << "#endif\n"
  f << "// #{ctr_pad}\n\n"
  
  (n - 1).times do |i|
    f << "#if #{stab}\n"
    f << "#endif\n"
  end
  f << "// #{ctr_pad * n}\n\n"

  f << "#ifndef ONCE\n"
  md = "((L >> #{ctr_pad_bits}) % #{sum})"
  f << "  #define R #{md}\n"
  f << "  #define Q1 (#{md} % #{n})\n"
  f << "  #define Q2 (#{md} % #{sum - n})\n"
  f << "  #line C\n"
  prom_check = "(R != 0 && Q1 == 0) || (R != 0 && Q2 == 0)"
  f << "  #if #{prom_check}\n"
  f << "    #define ONCE\n"
  f << "    #include \"inc.h\"\n"
  f << "    #include \"dec.h\"\n"
  f << "    #undef ONCE\n"
  f << "    #line C\n"
  f << "    #if #{prom_check}\n"
  f << "      #define ONCE\n"
  f << "      #include \"inc.h\"\n"
  f << "      #include \"dec.h\"\n"
  f << "      #undef ONCE\n"
  f << "    #endif\n"
  f << "  #endif\n\n"
  f << "  #undef IS_ZERO\n"
  if dec
    f << "  #line C\n"
    f << "  #if R == 0\n"
    f << "    #define IS_ZERO 1\n"
    f << "  #else\n"
    f << "    #define IS_ZERO 0\n"
    f << "  #endif\n"
  else
    f << "  #define IS_ZERO 0\n"
  end
  f << "#endif\n"
end

def generate_actions
  i = 5 # prime
  d = 7 # prime
  s = i + d
  c_pad = 2
  header = "inc.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    generate_action(f, i, s, c_pad, false)
  end
  header = "dec.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    generate_action(f, d, s, c_pad, true)
  end
end

def get_sym(sym)
  case sym
  when ""
    nil
  when "$"
    "END"
  else
    "A_#{sym}"
  end
end

def get_header(s, consume)
  consume ? "ctr_#{s}.h" : "ctr_#{s}_no_consume.h"
end

def generate_state(f, s, consume)
  header = get_header(s.name, consume)
  f << "/* #{header} */\n\n"
  f << "#include \"get_sym.h\"\n\n" if consume
  f << "#define RECOGNIZED\n\n" if s.final
  cond = "if"
  endif = false
  s.outgoing.each do |t|
    sym = get_sym(t.sym)
    cnd = []
    cnd << "CUR_SYM == #{sym}" unless sym.nil?
    case t.cond
    when :zero
      cnd << "IS_ZERO"
    when :positive
      cnd << "!IS_ZERO"
    end
    unless cnd.empty?
      endif = true
      cnd = cnd.join(" && ")
      f << "##{cond} #{cnd}\n"
    end
    f << "  #undef RECOGNIZED\n"
    case t.action
    when :inc
      f << "  #include \"inc.h\"\n"
    when :dec
      f << "  #include \"dec.h\"\n"
    end
    nxt = get_header(t.next, !sym.nil?)
    if !consume && sym
      f << "  #define NEXT_STATE \"#{nxt}\"\n"
      f << "  #define CONSUME\n"
    else
      f << "  #include \"#{nxt}\"\n"
    end
    cond = "elif"
  end
  f << "#endif\n" if endif

  if consume
    f << "\n"
    f << "#ifdef CONSUME\n"
    f << "  #undef CONSUME\n"
    f << "  #include NEXT_STATE\n"
    f << "#endif\n"
  end
end

def generate_states(ctr)
  ctr.states.each do |s|
    header = get_header(s.name, true)
    File.open(header, "w") do |f|
      generate_state(f, s, true)
    end
    next if s.consume
    header = get_header(s.name, false)
    File.open(header, "w") do |f|
      generate_state(f, s, false)
    end
  end
end

generate_header(ctr)
generate_get_sym(ctr)
generate_actions
generate_states(ctr)