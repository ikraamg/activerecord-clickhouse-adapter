# frozen_string_literal: true

# dump is the sink's largest column and the one the device-log queries scan, so a better ratio
# buys read I/O rather than disk. ZSTD roughly doubles LZ4's ratio on JSON for a little decode CPU.
#
# No MATERIALIZE: only new parts take the codec, and the table's 14-day TTL replaces every part
# well before rewriting the existing ones would pay for itself on a four-core host.
class CompressLogDumpsWithZstd < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE logs MODIFY COLUMN dump String CODEC(ZSTD(3))"
  end

  def down
    execute "ALTER TABLE logs MODIFY COLUMN dump String CODEC(LZ4)"
  end
end
