# -*- encoding: utf-8 -*-
require_relative '../../spec_helper'

describe :regexp_match, shared: true do
  it "returns nil if there is no match" do
    /xyz/.send(@method,"abxyc").should be_nil
  end

  it "returns nil if the object is nil" do
    /\w+/.send(@method, nil).should be_nil
  end
end

describe "Regexp#=~" do
  it_behaves_like :regexp_match, :=~

  it "returns the index of the first character of the matching region" do
    (/(.)(.)(.)/ =~ "abc").should == 0
  end

  it "returns the index too, when argument is a Symbol" do
    (/(.)(.)(.)/ =~ :abc).should == 0
  end
end

describe "Regexp#match" do
  it_behaves_like :regexp_match, :match

  it "returns a MatchData object" do
    /(.)(.)(.)/.match("abc").should be_kind_of(MatchData)
  end

  it "returns a MatchData object, when argument is a Symbol" do
    /(.)(.)(.)/.match(:abc).should be_kind_of(MatchData)
  end

  it "raises a TypeError on an uninitialized Regexp" do
    -> { Regexp.allocate.match('foo') }.should raise_error(TypeError)
  end

  it "raises TypeError on an uninitialized Regexp" do
    -> { Regexp.allocate.match('foo'.encode("UTF-16LE")) }.should raise_error(TypeError)
  end

  describe "with [string, position]" do
    describe "when given a positive position" do
      it "matches the input at a given position" do
        /(.).(.)/.match("01234", 1).captures.should == ["1", "3"]
      end

      # NATFIXME encoding isn't quite handled properly just yet
      xit "uses the start as a character offset" do
        /(.).(.)/.match("零一二三四", 1).captures.should == ["一", "三"]
      end

      # NATFIXME encoding isn't quite handled properly just yet
      xit "raises an ArgumentError for an invalid encoding" do
        x96 = ([150].pack('C')).force_encoding('utf-8')
        -> { /(.).(.)/.match("Hello, #{x96} world!", 1) }.should raise_error(ArgumentError)
      end
    end

    describe "when given a negative position" do
      it "matches the input at a given position" do
        /(.).(.)/.match("01234", -4).captures.should == ["1", "3"]
      end

      # NATFIXME encoding isn't quite handled properly just yet
      xit "uses the start as a character offset" do
        /(.).(.)/.match("零一二三四", -4).captures.should == ["一", "三"]
      end

      # NATFIXME encoding isn't quite handled properly just yet
      xit "raises an ArgumentError for an invalid encoding" do
        x96 = ([150].pack('C')).force_encoding('utf-8')
        -> { /(.).(.)/.match("Hello, #{x96} world!", -1) }.should raise_error(ArgumentError)
      end
    end

    describe "when passed a block" do
      it "yields the MatchData" do
        /./.match("abc") {|m| ScratchPad.record m }
        ScratchPad.recorded.should be_kind_of(MatchData)
      end

      it "returns the block result" do
        /./.match("abc") { :result }.should == :result
      end

      it "does not yield if there is no match" do
        ScratchPad.record []
        /a/.match("b") {|m| ScratchPad << m }
        ScratchPad.recorded.should == []
      end
    end
  end

  it "resets $~ if passed nil" do
    # set $~
    /./.match("a")
    $~.should be_kind_of(MatchData)

    /1/.match(nil)
    $~.should be_nil
  end

  it "raises TypeError when the given argument cannot be coerced to String" do
    f = 1
    -> { /foo/.match(f)[0] }.should raise_error(TypeError)
  end

  it "raises TypeError when the given argument is an Exception" do
    f = Exception.new("foo")
    -> { /foo/.match(f)[0] }.should raise_error(TypeError)
  end
end

describe "Regexp#match?" do
  before :each do
    # Resetting Regexp.last_match
    /DONTMATCH/.match ''
  end

  context "when matches the given value" do
    it "returns true but does not set Regexp.last_match" do
      /string/i.match?('string').should be_true
      Regexp.last_match.should be_nil
    end
  end

  it "returns false when does not match the given value" do
    /STRING/.match?('string').should be_false
  end

  it "takes matching position as the 2nd argument" do
    /str/i.match?('string', 0).should be_true
    /str/i.match?('string', 1).should be_false
  end

  it "returns false when given nil" do
    /./.match?(nil).should be_false
  end
end

describe "Regexp#~" do
  it "matches against the contents of $_" do
    $_ = "input data"
    (~ /at/).should == 7
  end
end
