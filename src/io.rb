class IO
  SEEK_SET = 0
  SEEK_CUR = 1
  SEEK_END = 2

  def rewind
    seek(0)
  end

  def each
    while line = gets
      yield line
    end
  end
end
