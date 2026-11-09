# frozen_string_literal: true

# Reads an API key from a file, strictly. The bench
# never reads a key from the environment.
#
# The file is opened ONCE, with O_NOFOLLOW (a symlink is refused), and every
# check is made on that open descriptor (fstat), so the file cannot be
# swapped between the check and the read:
#   - a regular file, owned by the current user,
#   - no group or other permission bits (0600 or stricter),
#   - at most 4,096 bytes and not empty,
#   - only printable ASCII (0x21-0x7E): no whitespace, control or non-ASCII
#     character anywhere, with ONE exception: exactly one trailing "\n" is
#     allowed (a key minted by a tool or an editor usually ends with one) and
#     is stripped from the value. A second newline, a CR ("\r\n"), a space
#     before the newline, or a newline anywhere else is refused.
#     The 4,096-byte limit counts the file as written, newline included.
#     The file is never modified.
#
# An error names the path and the rule that failed. It never contains any
# part of the file's content, not even the offending character.

module Bench
  class Error < StandardError; end unless const_defined?(:Error, false)
  class KeyFileRefused < Error; end

  module KeyFile
    MAX_BYTES = 4_096

    module_function

    # uid: the owner required (the current user); tests pass another one.
    def read(path, label: "key", uid: Process.euid)
      path = path.to_s
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat # fstat on the open descriptor
        refuse!(label, path, "is not a regular file") unless stat.file?
        refuse!(label, path, "is not owned by the current user") unless stat.uid == uid
        unless (stat.mode & 0o077).zero?
          refuse!(label, path, "has group or other permission bits (mode #{format("%04o", stat.mode & 0o7777)}); it must be 0600 or stricter")
        end
        refuse!(label, path, "is empty") if stat.size.zero?
        refuse!(label, path, "is larger than #{MAX_BYTES} bytes") if stat.size > MAX_BYTES

        value = file.read(MAX_BYTES + 1).to_s.b
        refuse!(label, path, "is larger than #{MAX_BYTES} bytes") if value.bytesize > MAX_BYTES
        value = value.delete_suffix("\n".b) # exactly one trailing newline; a second one stays and is refused below
        refuse!(label, path, "is empty") if value.empty?
        if (index = value.index(/[^\x21-\x7E]/n))
          refuse!(label, path, "has a character at byte #{index} that is not printable ASCII " \
                               "(no whitespace or control characters are allowed; one trailing newline is the only exception)")
        end
        value.force_encoding(Encoding::US_ASCII)
      end
    rescue Errno::ELOOP
      refuse!(label, path, "is a symlink")
    rescue SystemCallError => e
      refuse!(label, path, "cannot be opened (#{e.class})")
    end

    def refuse!(label, path, reason)
      raise KeyFileRefused, "#{label} file #{path} #{reason}; refusing before any request"
    end
  end
end
