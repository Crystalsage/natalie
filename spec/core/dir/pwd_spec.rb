# -*- encoding: utf-8 -*-
require_relative '../../spec_helper'
require_relative 'fixtures/common'
require_relative 'shared/pwd'

describe "Dir.pwd" do
  before :all do
    DirSpecs.create_mock_dirs
  end

  after :all do
    DirSpecs.delete_mock_dirs
  end

  it_behaves_like :dir_pwd, :pwd
end

describe "Dir.pwd" do
  before :each do
    @name = tmp("あ").force_encoding('binary')
    @fs_encoding = Encoding.find('filesystem')
  end

  after :each do
    rm_r @name
  end

  platform_is_not :windows do
    # NATFIXME: broken due to spec tmp() realpath issue
    xit "correctly handles dirs with unicode characters in them" do
      Dir.mkdir @name
      Dir.chdir @name do
        if @fs_encoding == Encoding::UTF_8
          Dir.pwd.encoding.should == Encoding::UTF_8
        end
        Dir.pwd.force_encoding('binary').should == @name
      end
    end
  end
end
