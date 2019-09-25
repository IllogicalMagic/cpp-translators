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
  attr_reader :next

  def initialize(trans_str)
    m = /\((\w+),(\w)\)->(\w+)/.match(trans_str)
    raise "Incorrect state string: #{trans_str}" if m.nil?
    @cur = m[1]
    @sym = m[2]
    @next = m[3]
  end

  def to_s
    "(#{@cur},#{@sym})->#{@next}"
  end
end

def parse_transitions(desc_str)
  m = /transitions=\{\(\w+,\w\)->\w+(,\(\w+,\w\)->\w+)*\}/.match(desc_str)
  raise "Bad transitions" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  trans = m[1].split(/,(?=\()/)
  trans = trans.map{ |c| Transition.new(c) }
  [trans, desc_str]
end

class State
  attr_reader :name
  attr_reader :transitions
  attr_reader :final

  def initialize(s, trans, final)
    @name = s
    @transitions = trans
    @final = final
  end

  def to_s
    final = @final ? " (final)" : ""
    str = "State #{name}#{final}. Transitions:\n"
    @transitions.each do |s, n|
      str += "Symbol #{s}, goto #{n}\n"
    end
    str
  end
end

class DFA
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

    state_to_next = Hash.new{ |h, k| h[k] = Hash.new }
    # initialize state to next with empty states
    states.each{ |s| state_to_next[s] }
    transitions.each do |trans|
      unless states.include?(trans.cur)
        raise "Transition #{trans} from unknown state #{trans.cur}"
      end
      unless states.include?(trans.next)
        raise "Transition #{trans} to unknown state #{trans.next}"
      end
      unless alphabet.include?(trans.sym)
        raise "Transition #{trans} by unknown symbol #{trans.sym}"
      end

      nxt = state_to_next[trans.cur]
      if nxt.include?(trans.sym)
        raise "Duplicate transition from state #{trans.cur} by symbol #{trans.sym}"
      end
      nxt[trans.sym] = trans.next
    end

    state_to_next.each do |s, trans|
      if trans.empty? && !final.include?(s)
        raise "Dead end non-final transition #{s}"
      end
    end

    @states = state_to_next.map{ |s, trans| State.new(s, trans, final.include?(s)) }
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
dfa = DFA.new(*desc)

puts dfa.states

Dir.mkdir(output) unless Dir.exist?(output)
Dir.chdir(output)

def generate_header(dfa)
  header = "dfa.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "/* alphabet */\n"
    logsize = (dfa.alphabet.size - 1).bit_length + 1
    dfa.alphabet.each_with_index do |a, i|
      n = i.to_s(2)
      n = "%0*d" % [logsize - 1, n]
      f << "#define A_#{a} 0b1#{n}\n"
    end
    f << "#define END 0\n"
    f << "#define A_MASK 0b#{((1 << logsize) - 1).to_s(2)}\n"
    f << "#define A_SIZE #{logsize}\n\n"
    
    f << "#define CTR (__COUNTER__ / (A_SIZE + 1))\n"
    f << "#define GET_SYM ((INPUT >> (CTR * A_SIZE)) & A_MASK)\n\n"

    f << "/* include initial state */\n"
    f << "#include \"dfa_#{dfa.initial}.h\"\n"
  end
end

def generate_get_sym(dfa)
  header = "get_sym.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    size = dfa.alphabet.size
    dfa.alphabet.each_with_index do |a, i|
      cond = i == 0 ? "if" : "elif"
      f << "##{cond} GET_SYM == A_#{a}\n"
      f << "  #define CUR_SYM A_#{a}\n"
      stabilize = (["CTR"] * (size - i)).join(",")
      f << "  #if 0,#{stabilize}\n"
      f << "  #endif\n"
    end
    f << "#elif GET_SYM == END\n"
    f << "  #define CUR_SYM END\n"
    f << "#endif\n"
  end
end

def generate_states(dfa)
  dfa.states.each do |s|
    header = "dfa_#{s.name}.h"
    File.open(header, "w") do |f|
      f << "/* #{header} */\n\n"
      f << "#include \"get_sym.h\"\n\n"
      s.transitions.each_with_index do |trans, i|
        cond = i == 0 ? "if" : "elif"
        f << "##{cond} CUR_SYM == A_#{trans[0]}\n"
        f << "  #include \"dfa_#{trans[1]}.h\"\n"
      end
      if s.final
        cond = s.transitions.empty? ? "if" : "elif"
        f << "##{cond} CUR_SYM == END\n"
        f << "  #define RECOGNIZED\n"
      end
      f << "#endif\n"
    end
  end
end

generate_header(dfa)
generate_get_sym(dfa)
generate_states(dfa)
