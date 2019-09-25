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
    # initialize state to next with empty states
    states.each{ |s| state_to_next[s] }
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

def generate_init_ctr
  File.open("init_ctr.h", "w") do |f|
    f << "/* init_ctr.h */\n\n"
    f << "#if __COUNTER__\n"
    f << "#endif\n"
    5.times do
      f << "#include \"stab.h\"\n"
    end
    f << "\n#define IS_ZERO 1\n"
  end
end

def generate_header(ctr)
  header = "ctr.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "#define LA (__LINE__ >> 2)\n"
    f << "#define CHECK2 ((LA - 1) & LA)\n"
    f << "#define CHECKSUB2 ((CHECK2 - 1) & CHECK2)\n"
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

    f << "#include \"init_ctr.h\"\n\n"

    f << "/* include initial state */\n"
    f << "#include \"ctr_#{ctr.initial}.h\"\n"
  end
end

def generate_get_sym(ctr)
  header = "get_sym.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "#undef CUR_SYM\n"
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

def generate_stab
  File.open("stab.h", "w") do |f|
    f << "/* stab.h */\n\n"
    f << "#if (__COUNTER__ & 3) != 0\n"
    f << "  #include \"stab.h\"\n"
    f << "#endif\n"
  end
end

def generate_next2pow
  File.open("next2pow.h", "w") do |f|
    f << "/* next2pow.h */\n\n"
    f << "#include \"stab.h\"\n\n"
    f << "#line __COUNTER__\n"
    f << "#if CHECK2 != 0\n"
    f << "  #include \"next2pow.h\"\n"
    f << "#endif\n"
  end
end

def generate_advance_msb
  File.open("advance_msb.h", "w") do |f|
    f << "/* advance_msb.h */\n\n"
    f << "#include \"stab.h\"\n\n"
    f << "#line __COUNTER__\n"
    f << "#if CHECKSUB2 != 0\n"
    f << "  #include \"advance_msb.h\"\n"
    f << "  #include \"stab.h\"\n"
    f << "#else\n"
    f << "  #include \"next2pow.h\"\n"
    f << "  #include \"stab.h\"\n"
    f << "#endif\n"
  end
end

def generate_inc
  File.open("inc.h", "w") do |f|
    f << "/* inc.h */\n\n"
    f << "#include \"advance_msb.h\"\n\n"
    f << "#undef IS_ZERO\n"
    f << "#define IS_ZERO 0\n"
  end
end

def generate_advance_lsb
  File.open("advance_lsb.h", "w") do |f|
    f << "/* advance_lsb.h */\n\n"
    f << "#include \"stab.h\"\n\n"
    f << "#line __COUNTER__\n"
    f << "#if CHECKSUB2 != 0\n"
    f << "  #include \"advance_lsb.h\"\n"
    f << "#endif\n"
  end
end

def generate_dec
  File.open("dec.h", "w") do |f|
    f << "/* dec.h */\n\n"
    f << "#include \"advance_lsb.h\"\n\n"
    f << "#line __COUNTER__\n"
    f << "#if ((LA >> 2) & LA) != 0\n"
    f << "  #undef IS_ZERO\n"
    f << "  #define IS_ZERO 1\n"
    f << "#endif\n"
  end
end

def generate_actions
  generate_stab
  generate_next2pow
  generate_advance_msb
  generate_inc
  generate_advance_lsb
  generate_dec
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
generate_init_ctr
generate_get_sym(ctr)
generate_actions
generate_states(ctr)
