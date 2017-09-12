require 'traject'
require 'marc'
require 'marc/marc4j'

# `Traject::Marc4JReader` uses the marc4j java package to parse the MARC records
# into standard ruby-marc MARC::Record objects. This reader may be faster than
# Traject::MarcReader, especially for XML.
#
# Marc4JReader can read MARC ISO 2709 ("binary") or MARCXML. We use the Marc4J MarcPermissiveStreamReader
# for reading binary, but sometimes in non-permissive mode, according to settings. We use the Marc4j MarcXmlReader
# for reading xml. The actual code for dealing with Marc4J is in the separate
# [marc-marc4j gem](https://github.com/billdueber/ruby-marc-marc4j).
#
# See also the pure ruby Traject::MarcReader as an alternative, if you need to read
# marc-in-json, or if you don't need binary Marc8 support, it may in some cases
# be faster.
#
# ## Settings
#
# * marc_source.type:     serialization type. default 'binary', also 'xml' (TODO: json/marc-in-json)
#
# * marc4j_reader.permissive:   default true, false to turn off permissive reading. Used as
#                             value to 'permissive' arg of MarcPermissiveStreamReader constructor.
#                             Only used for 'binary'
#
# * marc_source.encoding: Only used for 'binary', otherwise always UTF-8.
#         String of the values MarcPermissiveStreamReader accepts:
#         * BESTGUESS  (default: not entirely clear what Marc4J does with this)
#         * ISO-8859-1 (also accepted: ISO8859_1)
#         * UTF-8
#         * MARC-8 (also accepted: MARC8)
#         Default 'BESTGUESS', but HIGHLY recommend setting
#         to avoid some Marc4J unpredictability, Marc4J "BESTGUESS" can be unpredictable
#         in a variety of ways.
#         (will ALWAYS be transcoded to UTF-8 on the way out. We insist.)
#
# * marc4j_reader.jar_dir: Path to a directory containing Marc4J jar file to use. All .jar's in dir will
#                          be loaded. If unset, uses marc4j.jar bundled with traject.
#
# * marc4j_reader.keep_marc4j: Keeps the original marc4j record accessible from
#   the eventual ruby-marc record via record#original_marc4j. Intended for
#   those that have legacy java code for which a marc4j object is needed. .
#
#
# ## Example
#
# In a configuration file:
#
#     require 'traject/marc4j_reader
#     settings do
#       provide "reader_class_name", "Traject::Marc4JReader"
#
#       #for MarcXML:
#       # provide "marc_source.type", "xml"
#
#       # Or instead for binary:
#       provide "marc4j_reader.permissive", true
#       provide "marc_source.encoding", "MARC8"
#     end
class Traject::Marc4JReader
  include Enumerable

  attr_reader :settings, :input_stream

  def initialize(input_stream, settings)
    @settings     = Traject::Indexer::Settings.new settings
    @input_stream = input_stream

    if @settings['marc4j_reader.keep_marc4j'] &&
        ! (MARC::Record.instance_methods.include?(:original_marc4j) &&
            MARC::Record.instance_methods.include?(:"original_marc4j="))
      MARC::Record.class_eval('attr_accessor :original_marc4j')
    end

    # Creating a converter will do the following:
    #  - nothing, if it detects that the marc4j jar is already loaded
    #  - load all the .jar files in settings['marc4j_reader.jar_dir'] if set
    #  - load the marc4j jar file bundled with MARC::MARC4J otherwise

    @converter = MARC::MARC4J.new(:jardir => settings['marc4j_reader.jar_dir'], :logger => logger)

    # Convenience
    java_import org.marc4j.MarcPermissiveStreamReader
    java_import org.marc4j.MarcStreamReader
    java_import org.marc4j.MarcXmlReader

  end


  def internal_reader
    @internal_reader ||= create_marc_reader!
  end

  def input_type
    # maybe later add some guessing somehow
    settings["marc_source.type"]
  end

  def specified_source_encoding
    #settings["marc4j_reader.source_encoding"]
    enc = settings["marc_source.encoding"]

    # one is standard for ruby and we want to support,
    # the other is used by Marc4J and we have to pass it to Marc4J
    enc = "ISO8859_1" if enc == "ISO-8859-1"

    # default
    enc = "BESTGUESS" if enc.nil? || enc.empty?

    return enc
  end

  def create_marc_reader!
    case input_type
    when "binary"
      the_stream = input_stream.to_inputstream
      if settings["marc4j_reader.permissive"].to_s == "true"

        # #to_inputstream turns our ruby IO into a Java InputStream
        # third arg means 'convert to UTF-8, yes'
        MarcPermissiveStreamReader.new(the_stream, true, true, specified_source_encoding)
      else
        MarcStreamReader(the_stream, specified_source_encoding)
      end
    when "xml"
      MarcXmlReader.new(input_stream.to_inputstream)
    else
      raise IllegalArgument.new("Unrecgonized marc_source.type: #{input_type}")
    end
  end

  def each
    while (internal_reader.hasNext)
      begin
        marc4j = internal_reader.next
        rubymarc = @converter.marc4j_to_rubymarc(marc4j)
        if @settings['marc4j_reader.keep_marc4j']
          rubymarc.original_marc4j = marc4j
        end
      rescue Exception =>e
        msg = "MARC4JReader: Error reading MARC, fatal, re-raising"
        if marc4j
          msg += "\n    001 id: #{marc4j.getControlNumber}"
        end
        msg += "\n    #{Traject::Util.exception_to_log_message(e)}"
        logger.fatal msg
        raise e
      end

      yield rubymarc
    end
  end

  def logger
    @logger ||= (settings[:logger] || Yell.new(STDERR, :level => "gt.fatal")) # null logger)
  end

end
