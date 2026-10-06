# frozen_string_literal: true

module Net
  class IMAP < Protocol

    # MetadataData represents the contents of an untagged +METADATA+ response,
    # as defined by {RFC 5464}[https://www.rfc-editor.org/rfc/rfc5464].
    #
    # #mailbox is the empty string for server entries.  #entries maps metadata
    # entry names to their returned values.  #omitted lists entries named by the
    # server without values, for example entries which exceeded GETMETADATA
    # +MAXSIZE+.
    class MetadataData < Data.define(:mailbox, :entries, :omitted)
      # :call-seq: mailbox -> string
      #
      # The mailbox to which the entries belong, or +""+ for server entries.

      # :call-seq: entries -> hash
      #
      # A hash of metadata entry names and their values.

      alias values entries

      # :call-seq: omitted -> array of strings
      #
      # Entry names returned without values.
    end

    # Returned by Net::IMAP#getmetadata.
    #
    # #entries includes every returned entry.  Omitted entries are also placed
    # in #entries with +nil+ values for convenient hash access, and listed in
    # #omitted.  #longentries is the integer from a +LONGENTRIES+ response
    # code, when present.
    class GetMetadataResult < Data.define(:mailbox, :entries, :omitted,
                                         :depth, :maxsize, :longentries)
      def initialize(mailbox:, entries:, omitted: [], depth: nil,
                     maxsize: nil, longentries: nil)
        entries = omitted.each_with_object(entries.dup) { _2[_1] = nil }
        super(mailbox:, entries:, omitted: omitted.dup, depth:,
              maxsize:, longentries:)
      end

      # Returns the metadata value for +entry+.
      def [](entry) = entries[entry]

      # Returns +true+ when +entry+ was returned.
      def key?(entry) = entries.key?(entry)
      alias has_key? key?

      # Iterates over returned entry names and values.
      def each(...) = entries.each(...)

      # Returns the number of returned and omitted entries.
      def size = entries.size
      alias length size

      def to_h(*)
        super.merge(omitted: omitted.dup)
      end
      alias to_hash to_h
    end

  end
end
