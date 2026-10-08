# frozen_string_literal: true

class Uncovered
  def untouched(flag)
    flag ? :unexecuted : nil
  end
end
