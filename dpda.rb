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

def parse_symbols(desc_str, type)
  m = /#{type}=\{\w(,\w)*\}/i.match(desc_str)
  raise "Bad #{type}" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  alphabet = m[1].split(",")
  [alphabet, desc_str]
end

def parse_alphabet(desc_str)
  parse_symbols(desc_str, "alphabet")
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

def parse_stack(desc_str)
  parse_symbols(desc_str, "stack")
end

def parse_bottom(desc_str)
  m = /bottom=\w/i.match(desc_str)
  raise "Bad initial stack symbol" if m.nil?
  desc_str = m.post_match.lstrip
  initial = m[0].split("=")[1]
  [initial, desc_str]
end

class Transition
  attr_reader :cur
  attr_reader :sym
  attr_reader :top
  attr_reader :next
  attr_reader :push

  def initialize(trans_str)
    m = /\((\w+),((?:\w|\$)?),(\w)\)->\((\w+),(\w*)\)/.match(trans_str)
    raise "Incorrect state string: #{trans_str}" if m.nil?
    @cur = m[1]
    @sym = m[2]
    @top = m[3]
    @next = m[4]
    @push = m[5]
  end

  def to_s
    "(#{@cur},#{@sym},#{@top})->(#{@next},#{@push})"
  end
end

def parse_transitions(desc_str)
  m = /transitions=\{\(\w+,(\w|\$)?,\w\)->\(\w+,\w*\)(,\(\w+,(\w|\$)?,\w\)->\(\w+,\w*\))*\}/.match(desc_str)
  raise "Bad transitions" if m.nil?
  desc_str = m.post_match.lstrip
  m = /\{(.*)\}/.match(m[0])
  trans = m[1].split(/,(?=\()/)
  trans = trans.map{ |c| Transition.new(c) }
  [trans, desc_str]
end

class Edge
  attr_reader :sym
  attr_reader :top
  attr_reader :next
  attr_reader :action
  attr_reader :stack_sym

  def initialize(sym, top, nxt, action, stack_sym)
    @sym = sym
    @top = top
    @next = nxt
    @action = action
    @stack_sym = stack_sym
  end
end

class AtomTransition
  attr_reader :cur
  attr_reader :sym
  attr_reader :top
  attr_reader :next
  attr_reader :action
  attr_reader :stack_sym

  def initialize(cur, sym, top, nxt, action, stack_sym = nil)
    @cur = cur
    @sym = sym
    @top = top
    @next = nxt
    @action = action
    @stack_sym = stack_sym
  end
end

class State
  attr_reader :name
  attr_reader :outgoing
  attr_reader :empty
  attr_reader :final

  def initialize(s, trans, empty, final)
    @name = s
    @outgoing = trans
    @empty = empty
    @final = final
  end

  def to_s
    props = []
    props << "empty" if @empty
    props << "final" if @final
    props = props.empty? ? "" : " (#{props.join(', ')})"
    str = "State #{name}#{props}. Transitions:\n"
    @outgoing.each do |e|
      case e.action
      when :push
        action = "push #{e.stack_sym}"
      when :replace
        action = "replace by #{e.stack_sym}"
      when :pop
        action = "pop"
      end
      symbol = e.sym.empty? ? "No symbol" : "Symbol #{e.sym}"
      str += "#{symbol}, top #{e.top}, goto #{e.next}, #{action}\n"
    end
    str
  end
end

class DPDA
  attr_reader :alphabet
  attr_reader :states
  attr_reader :initial
  attr_reader :stack
  attr_reader :bottom

  def initialize(alphabet, states, initial, final, stack, bottom, transitions)
    @alphabet = alphabet
    @initial = initial
    @stack = stack
    unless stack.include?(bottom)
      raise "Start stack symbol do not belong to stack symbols"
    end
    @bottom = bottom
    build_states(states, transitions, final)
  end

  private

  def atomize_transitions(transitions)
    atom_trans = []
    transitions.each do |trans|
      if trans.push.empty?
        t = AtomTransition.new(trans.cur, trans.sym, trans.top, trans.next, :pop)
        atom_trans << t
        next
      end
      if trans.push.size == 1
        t = AtomTransition.new(trans.cur, trans.sym, trans.top, trans.next, :replace, trans.push)
        atom_trans << t
        next
      end

      repl = false
      if trans.top != trans.push[-1]
        nxt = "#{trans.cur}.#{0}"
        t = AtomTransition.new(trans.cur, trans.sym, trans.top, nxt, :replace, trans.push[-1])
        atom_trans << t
        repl = true
      end
      trans.push.reverse.each_char.each_cons(2).with_index do |s, i|
        top = s[0]
        push = s[1]
        if !repl && i == 0
          cur = trans.cur
          sym = trans.sym
        else
          cur = "#{trans.cur}.#{i}"
          sym = ""
        end
        nxt = i + 1 == trans.push.size - 1 ? trans.next : "#{trans.cur}.#{i + 1}"
        cur = AtomTransition.new(cur, sym, top, nxt, :push, push)
        atom_trans << cur
      end
    end
    atom_trans
  end

  def build_states(states, transitions, final)
    alphabet = @alphabet.to_set
    stack = @stack.to_set
    states = states.to_set
    final = final.to_set

    unless states.include?(@initial)
      raise "Initial state #{@initial} doesn't belong to states set"
    end

    final.each do |f|
      unless states.include?(f)
        raise "Final state #{final} doesn't belong to states set"
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
      unless stack.include?(trans.top)
        raise "Transition #{trans} by unknown stack symbol #{trans.top}"
      end
      trans.push.each_char do |s|
        unless stack.include?(trans.top)
          raise "Transition #{trans} pushes unknown stack symbol #{s}"
        end
      end
    end

    transitions = atomize_transitions(transitions)

    state_to_next = Hash.new{ |h, k| h[k] = Array.new }
    empty_states = Set.new
    transitions.each do |trans|
      nxt = state_to_next[trans.cur]
      nxt << Edge.new(trans.sym, trans.top, trans.next, trans.action, trans.stack_sym)
      empty_states.add(trans.next) if trans.action != :push
    end

    state_to_next.each do |s, trans|
      if trans.empty? && !final.include?(s)
        raise "Dead end non-final transition #{s}"
      end
    end
    finals = states - state_to_next.each_key.to_set
    finals.each do |f|
      state_to_next[f] = []
    end

    @states = state_to_next.map do  |s, trans|
      State.new(s, trans, empty_states.include?(s), final.include?(s))
    end
  end
end

def parse_description(desc_str)
  desc_str = desc_str.delete(" \t\r\f\v").tr("\n", " ")
  alphabet, desc_str = parse_alphabet(desc_str)
  states, desc_str = parse_states(desc_str)
  initial, desc_str = parse_initial(desc_str)
  final, desc_str = parse_final(desc_str)
  stack, desc_str = parse_stack(desc_str)
  bottom, desc_str = parse_bottom(desc_str)
  trans, desc_str = parse_transitions(desc_str)
  [alphabet, states, initial, final, stack, bottom, trans]
end

desc_str = ""
File.open(input, "r") do |f|
  desc_str = f.read
end

desc = parse_description(desc_str)
dpda = DPDA.new(*desc)

puts dpda.states

Dir.mkdir(output) unless Dir.exists?(output)
Dir.chdir(output)

def generate_header(dpda)
  header = "dpda.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "/* alphabet */\n"
    logsize = (dpda.alphabet.size - 1).bit_length + 1
    dpda.alphabet.each_with_index do |a, i|
      n = i.to_s(2)
      n = "%0*d" % [logsize - 1, n]
      f << "#define A_#{a} 0b1#{n}\n"
    end
    f << "#define END 0\n"
    f << "#define A_MASK 0b#{((1 << logsize) - 1).to_s(2)}\n"
    f << "#define A_SIZE #{logsize}\n\n"

    f << "#define TOP(L) (__LINE__ - (L))\n"
    dpda.stack.each_with_index do |s, i|
      f << "#define ST_#{s} #{i}\n"
    end
    f << "#define NEXT_ST_SYM ST_#{dpda.bottom}\n\n"
    
    f << "#define CTR (__COUNTER__ / (A_SIZE + 1))\n"
    f << "#define GET_SYM ((INPUT >> (CTR * A_SIZE)) & A_MASK)\n\n"

    f << "/* include initial state */\n"
    f << "#include \"dpda_#{dpda.initial}.h\"\n"
  end
end

def generate_get_sym(dpda)
  header = "get_sym.h"
  File.open(header, "w") do |f|
    f << "/* #{header} */\n\n"
    f << "#ifndef CUR_SYM\n\n"
    size = dpda.alphabet.size
    dpda.alphabet.each_with_index do |a, i|
      cond = i == 0 ? "if" : "elif"
      f << "##{cond} GET_SYM == A_#{a}\n"
      f << "  #define CUR_SYM A_#{a}\n"
      stabilize = (["CTR"] * (size - i)).join(",")
      f << "  #if 0,#{stabilize}\n"
      f << "  #endif\n"
    end
    f << "#elif GET_SYM == END\n"
    f << "  #define CUR_SYM END\n"
    f << "#endif\n\n"
    f << "#endif\n"
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

def get_header(s, empty)
  empty ? "dpda_#{s.name}_empty.h" : "dpda_#{s.name}.h"
end

def generate_state(f, s, stack, empty)
  header = get_header(s, empty)
  f << "/* #{header} */\n\n"
  f << "#include \"get_sym.h\"\n\n"
  f << "#define RECOGNIZED\n\n" if s.final
  f << "#line NEXT_ST_SYM\n\n"
  line = 1
  cond = "if"
  s.outgoing.each do |t|
    sym = get_sym(t.sym)
    f << "##{cond} TOP(#{line}) == ST_#{t.top}"
    f << " && CUR_SYM == #{sym}" unless sym.nil?
    f << "\n"
    f << "  #undef RECOGNIZED\n"
    line += 2
    f << "  #undef CUR_SYM\n" unless sym.nil?
    line += 1 unless sym.nil?
    case t.action
    when :push
      f << "  #define NEXT_ST_SYM ST_#{t.stack_sym}\n"
      f << "  #include \"dpda_#{t.next}.h\"\n"
      line += 2
    when :pop
      f << "  #define NEXT_STATE \"dpda_#{t.next}_empty.h\"\n"
      f << "  #define POP\n"
      line += 2
    when :replace
      f << "  #define NEXT_ST_SYM ST_#{t.stack_sym}\n"
      f << "  #include \"dpda_#{t.next}_empty.h\"\n"
      line += 2
    end
    cond = "elif"
  end
  f << "#endif\n\n" unless s.outgoing.empty?
  line += 2 unless s.outgoing.empty?

  f << "#ifndef RECOGNIZED\n"
  f << "#ifndef POP\n"
  line += 2
  cond = "if"
  stack.each do |st|
    f << "  ##{cond} TOP(#{line}) == ST_#{st}\n"
    f << "    #define NEXT_ST_SYM ST_#{st}\n"
    line += 2
    cond = "elif"
  end
  f << "  #endif\n"
  f << "  #include NEXT_STATE\n"
  f << "#endif\n"
  f << "#undef POP\n" unless empty
  f << "#endif\n"
end

def generate_states(dpda)
  dpda.states.each do |s|
    header = get_header(s, false)
    File.open(header, "w") do |f|
      generate_state(f, s, dpda.stack, false)
    end
    next unless s.empty
    header = get_header(s, true)
    File.open(header, "w") do |f|
      generate_state(f, s, dpda.stack, true)
    end
  end
end

generate_header(dpda)
generate_get_sym(dpda)
generate_states(dpda)
