# typed: false
# frozen_string_literal: true

require "json"
require "time"
require "unpack_strategy"
require "lazy_object"
require "cgi"
require "lock_file"

require "mechanize/version"
require "mechanize/http/content_disposition_parser"

require "utils/curl"
require "utils/github"

require "github_packages"

require "extend/time"
using TimeRemaining

# @abstract Abstract superclass for all download strategies.
#
# @api private
class AbstractDownloadStrategy
  extend T::Sig

  extend Forwardable
  include FileUtils
  include Context

  # Extension for bottle downloads.
  #
  # @api private
  module Pourable
    def stage
      ohai "Pouring #{basename}"
      super
    end
  end

  # The download URL.
  #
  # @api public
  sig { returns(String) }
  attr_reader :url

  # Location of the cached download.
  #
  # @api public
  sig { returns(Pathname) }
  attr_reader :cached_location

  attr_reader :cache, :meta, :name, :version

  private :meta, :name, :version

  def initialize(url, name, version, **meta)
    @url = url
    @name = name
    @version = version
    @cache = meta.fetch(:cache, HOMEBREW_CACHE)
    @meta = meta
    @quiet = false
    extend Pourable if meta[:bottle]
  end

  # Download and cache the resource at {#cached_location}.
  #
  # @api public
  def fetch(timeout: nil); end

  # Disable any output during downloading.
  #
  # TODO: Deprecate once we have an explicitly documented alternative.
  #
  # @api public
  sig { void }
  def shutup!
    @quiet = true
  end

  def quiet?
    Context.current.quiet? || @quiet
  end

  # Unpack {#cached_location} into the current working directory.
  #
  # Additionally, if a block is given, the working directory was previously empty
  # and a single directory is extracted from the archive, the block will be called
  # with the working directory changed to that directory. Otherwise this method
  # will return, or the block will be called, without changing the current working
  # directory.
  #
  # @api public
  def stage(&block)
    UnpackStrategy.detect(cached_location,
                          prioritize_extension: true,
                          ref_type: @ref_type, ref: @ref)
                  .extract_nestedly(basename:             basename,
                                    prioritize_extension: true,
                                    verbose:              verbose? && !quiet?)
    chdir(&block) if block
  end

  def chdir(&block)
    entries = Dir["*"]
    raise "Empty archive" if entries.empty?

    if entries.length != 1
      yield
      return
    end

    if File.directory? entries.first
      Dir.chdir(entries.first, &block)
    else
      yield
    end
  end
  private :chdir

  # @!attribute [r] source_modified_time
  # Returns the most recent modified time for all files in the current working directory after stage.
  #
  # @api public
  sig { returns(Time) }
  def source_modified_time
    Pathname.pwd.to_enum(:find).select(&:file?).map(&:mtime).max
  end

  # Remove {#cached_location} and any other files associated with the resource
  # from the cache.
  #
  # @api public
  def clear_cache
    rm_rf(cached_location)
  end

  def basename
    cached_location.basename
  end

  private

  def puts(*args)
    super(*args) unless quiet?
  end

  def ohai(*args)
    super(*args) unless quiet?
  end

  def silent_command(*args, **options)
    system_command(*args, print_stderr: false, env: env, **options)
  end

  def command!(*args, **options)
    system_command!(
      *args,
      env: env.merge(options.fetch(:env, {})),
      **command_output_options,
      **options,
    )
  end

  def command_output_options
    {
      print_stdout: !quiet?,
      print_stderr: !quiet?,
      verbose:      verbose? && !quiet?,
    }
  end

  def env
    {}
  end
end

# @abstract Abstract superclass for all download strategies downloading from a version control system.
#
# @api private
class VCSDownloadStrategy < AbstractDownloadStrategy
  REF_TYPES = [:tag, :branch, :revisions, :revision].freeze

  def initialize(url, name, version, **meta)
    super
    @ref_type, @ref = extract_ref(meta)
    @revision = meta[:revision]
    @cached_location = @cache/"#{name}--#{cache_tag}"
  end

  # Download and cache the repository at {#cached_location}.
  #
  # @api public
  def fetch(timeout: nil)
    end_time = Time.now + timeout if timeout

    ohai "Cloning #{url}"

    if cached_location.exist? && repo_valid?
      puts "Updating #{cached_location}"
      update(timeout: timeout)
    elsif cached_location.exist?
      puts "Removing invalid repository from cache"
      clear_cache
      clone_repo(timeout: end_time)
    else
      clone_repo(timeout: end_time)
    end

    version.update_commit(last_commit) if head?

    return if @ref_type != :tag || @revision.blank? || current_revision.blank? || current_revision == @revision

    raise <<~EOS
      #{@ref} tag should be #{@revision}
      but is actually #{current_revision}
    EOS
  end

  def fetch_last_commit
    fetch
    last_commit
  end

  def commit_outdated?(commit)
    @last_commit ||= fetch_last_commit
    commit != @last_commit
  end

  def head?
    version.respond_to?(:head?) && version.head?
  end

  # @!attribute [r] last_commit
  # Return last commit's unique identifier for the repository.
  # Return most recent modified timestamp unless overridden.
  #
  # @api public
  sig { returns(String) }
  def last_commit
    source_modified_time.to_i.to_s
  end

  private

  def cache_tag
    raise NotImplementedError
  end

  def repo_valid?
    raise NotImplementedError
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil); end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil); end

  def current_revision; end

  def extract_ref(specs)
    key = REF_TYPES.find { |type| specs.key?(type) }
    [key, specs[key]]
  end
end

# @abstract Abstract superclass for all download strategies downloading a single file.
#
# @api private
class AbstractFileDownloadStrategy < AbstractDownloadStrategy
  # Path for storing an incomplete download while the download is still in progress.
  #
  # @api public
  def temporary_path
    @temporary_path ||= Pathname.new("#{cached_location}.incomplete")
  end

  # Path of the symlink (whose name includes the resource name, version and extension)
  # pointing to {#cached_location}.
  #
  # @api public
  def symlink_location
    return @symlink_location if defined?(@symlink_location)

    ext = Pathname(parse_basename(url)).extname
    @symlink_location = @cache/"#{name}--#{version}#{ext}"
  end

  # Path for storing the completed download.
  #
  # @api public
  def cached_location
    return @cached_location if defined?(@cached_location)

    url_sha256 = Digest::SHA256.hexdigest(url)
    downloads = Pathname.glob(HOMEBREW_CACHE/"downloads/#{url_sha256}--*")
                        .reject { |path| path.extname.end_with?(".incomplete") }

    @cached_location = if downloads.count == 1
      downloads.first
    else
      HOMEBREW_CACHE/"downloads/#{url_sha256}--#{resolved_basename}"
    end
  end

  def basename
    cached_location.basename.sub(/^[\da-f]{64}--/, "")
  end

  private

  def resolved_url
    resolved_url, = resolved_url_and_basename
    resolved_url
  end

  def resolved_basename
    _, resolved_basename = resolved_url_and_basename
    resolved_basename
  end

  def resolved_url_and_basename
    return @resolved_url_and_basename if defined?(@resolved_url_and_basename)

    @resolved_url_and_basename = [url, parse_basename(url)]
  end

  def parse_basename(url, search_query: true)
    uri_path = if url.match?(URI::DEFAULT_PARSER.make_regexp)
      uri = URI(url)

      if uri.query
        query_params = CGI.parse(uri.query)
        query_params["response-content-disposition"].each do |param|
          query_basename = param[/attachment;\s*filename=(["']?)(.+)\1/i, 2]
          return File.basename(query_basename) if query_basename
        end
      end

      if uri.query && search_query
        "#{uri.path}?#{uri.query}"
      else
        uri.path
      end
    else
      url
    end

    uri_path = URI.decode_www_form_component(uri_path)
    query_regex = /[^?&]+/

    # We need a Pathname because we've monkeypatched extname to support double
    # extensions (e.g. tar.gz).
    # Given a URL like https://example.com/download.php?file=foo-1.0.tar.gz
    # the basename we want is "foo-1.0.tar.gz", not "download.php".
    Pathname.new(uri_path).ascend do |path|
      ext = path.extname[query_regex]
      return path.basename.to_s[/#{query_regex.source}#{Regexp.escape(ext)}/] if ext
    end

    # Strip query string
    File.basename(uri_path)[query_regex]
  end
end

# Strategy for downloading files using `curl`.
#
# @api public
class CurlDownloadStrategy < AbstractFileDownloadStrategy
  include Utils::Curl

  attr_reader :mirrors

  def initialize(url, name, version, **meta)
    super
    @try_partial = true
    @mirrors = meta.fetch(:mirrors, [])
  end

  # Download and cache the file at {#cached_location}.
  #
  # @api public
  def fetch(timeout: nil)
    end_time = Time.now + timeout if timeout

    download_lock = LockFile.new(temporary_path.basename)
    download_lock.lock

    urls = [url, *mirrors]

    begin
      url = urls.shift

      ohai "Downloading #{url}"

      resolved_url, _, url_time, _, is_redirection =
        resolve_url_basename_time_file_size(url, timeout: end_time&.remaining!)
      # Authorization is no longer valid after redirects
      meta[:headers]&.delete_if { |header| header.start_with?("Authorization") } if is_redirection

      fresh = if cached_location.exist? && url_time
        url_time <= cached_location.mtime
      elsif version.respond_to?(:latest?)
        !version.latest?
      else
        true
      end

      if cached_location.exist? && fresh
        puts "Already downloaded: #{cached_location}"
      else
        begin
          _fetch(url: url, resolved_url: resolved_url, timeout: end_time&.remaining!)
        rescue ErrorDuringExecution
          raise CurlDownloadStrategyError, url
        end
        ignore_interrupts do
          cached_location.dirname.mkpath
          temporary_path.rename(cached_location)
          symlink_location.dirname.mkpath
        end
      end

      FileUtils.ln_s cached_location.relative_path_from(symlink_location.dirname), symlink_location, force: true
    rescue CurlDownloadStrategyError
      raise if urls.empty?

      puts "Trying a mirror..."
      retry
    rescue Timeout::Error => e
      raise Timeout::Error, "Timed out downloading #{self.url}: #{e}"
    end
  ensure
    download_lock&.unlock
    download_lock&.path&.unlink
  end

  def clear_cache
    super
    rm_rf(temporary_path)
  end

  def resolved_time_file_size(timeout: nil)
    _, _, time, file_size = resolve_url_basename_time_file_size(url, timeout: timeout)
    [time, file_size]
  end

  private

  def resolved_url_and_basename(timeout: nil)
    resolved_url, basename, = resolve_url_basename_time_file_size(url, timeout: nil)
    [resolved_url, basename]
  end

  def resolve_url_basename_time_file_size(url, timeout: nil)
    @resolved_info_cache ||= {}
    return @resolved_info_cache[url] if @resolved_info_cache.include?(url)

    if (domain = Homebrew::EnvConfig.artifact_domain)
      url = url.sub(%r{^https?://#{GitHubPackages::URL_DOMAIN}/}o, "#{domain.chomp("/")}/")
    end

    output, _, _status = curl_output(
      "--location", "--silent", "--head", "--request", "GET", url.to_s,
      timeout: timeout
    )
    parsed_output = parse_curl_output(output)

    lines = output.to_s.lines.map(&:chomp)

    final_url = curl_response_follow_redirections(parsed_output[:responses], url)
    final_url ||= url

    content_disposition_parser = Mechanize::HTTP::ContentDispositionParser.new

    parse_content_disposition = lambda do |line|
      next unless (content_disposition = content_disposition_parser.parse(line.sub(/; *$/, ""), true))

      filename = nil

      if (filename_with_encoding = content_disposition.parameters["filename*"])
        encoding, encoded_filename = filename_with_encoding.split("''", 2)
        # If the `filename*` has incorrectly added double quotes, e.g.
        #   content-disposition: attachment; filename="myapp-1.2.3.pkg"; filename*=UTF-8''"myapp-1.2.3.pkg"
        # Then the encoded_filename will come back as the empty string, in which case we should fall back to the
        # `filename` parameter.
        if encoding && encoded_filename.present?
          filename = URI.decode_www_form_component(encoded_filename).encode(encoding)
        end
      end

      # Servers may include '/' in their Content-Disposition filename header. Take only the basename of this, because:
      # - Unpacking code assumes this is a single file - not something living in a subdirectory.
      # - Directory traversal attacks are possible without limiting this to just the basename.
      File.basename(filename || content_disposition.filename)
    end

    filenames = lines.map(&parse_content_disposition).compact

    time =
      lines.map { |line| line[/^Last-Modified:\s*(.+)/i, 1] }
           .compact
           .map { |t| t.match?(/^\d+$/) ? Time.at(t.to_i) : Time.parse(t) }
           .last

    file_size =
      lines.map { |line| line[/^Content-Length:\s*(\d+)/i, 1] }
           .compact
           .map(&:to_i)
           .last

    is_redirection = url != final_url
    basename = filenames.last || parse_basename(final_url, search_query: !is_redirection)

    @resolved_info_cache[url] = [final_url, basename, time, file_size, is_redirection]
  end

  def _fetch(url:, resolved_url:, timeout:)
    ohai "Downloading from #{resolved_url}" if url != resolved_url

    if Homebrew::EnvConfig.no_insecure_redirect? &&
       url.start_with?("https://") && !resolved_url.start_with?("https://")
      $stderr.puts "HTTPS to HTTP redirect detected and HOMEBREW_NO_INSECURE_REDIRECT is set."
      raise CurlDownloadStrategyError, url
    end

    _curl_download resolved_url, temporary_path, timeout
  end

  def _curl_download(resolved_url, to, timeout)
    curl_download resolved_url, to: to, try_partial: @try_partial, timeout: timeout
  end

  # Curl options to be always passed to curl,
  # with raw head calls (`curl --head`) or with actual `fetch`.
  def _curl_args
    args = []

    args += ["-b", meta.fetch(:cookies).map { |k, v| "#{k}=#{v}" }.join(";")] if meta.key?(:cookies)

    args += ["-e", meta.fetch(:referer)] if meta.key?(:referer)

    args += ["--user", meta.fetch(:user)] if meta.key?(:user)

    args += [meta[:header], meta[:headers]].flatten.compact.flat_map { |h| ["--header", h.strip] }

    if meta[:insecure]
      unless @insecure_warning_shown
        opoo "Using --insecure with curl to download `ca-certificates` " \
             "because we need it installed to download securely from now on. " \
             "Checksums will still be verified."
        @insecure_warning_shown = true
      end
      args += ["--insecure"]
    end

    args
  end

  def _curl_opts
    return { user_agent: meta.fetch(:user_agent) } if meta.key?(:user_agent)

    {}
  end

  def curl_output(*args, **options)
    super(*_curl_args, *args, **_curl_opts, **options)
  end

  def curl(*args, **options)
    options[:connect_timeout] = 15 unless mirrors.empty?
    super(*_curl_args, *args, **_curl_opts, **command_output_options, **options)
  end
end

# Strategy for downloading a file using homebrew's curl.
#
# @api public
class HomebrewCurlDownloadStrategy < CurlDownloadStrategy
  private

  def _curl_download(resolved_url, to, timeout)
    raise HomebrewCurlDownloadStrategyError, url unless Formula["curl"].any_version_installed?

    curl_download resolved_url, to: to, try_partial: @try_partial, timeout: timeout, use_homebrew_curl: true
  end

  def curl_output(*args, **options)
    raise HomebrewCurlDownloadStrategyError, url unless Formula["curl"].any_version_installed?

    options[:use_homebrew_curl] = true
    super(*args, **options)
  end
end

# Strategy for downloading a file from an GitHub Packages URL.
#
# @api public
class CurlGitHubPackagesDownloadStrategy < CurlDownloadStrategy
  attr_writer :resolved_basename

  def initialize(url, name, version, **meta)
    meta ||= {}
    meta[:headers] ||= []
    # GitHub Packages authorization header.
    # HOMEBREW_GITHUB_PACKAGES_AUTH set in brew.sh
    meta[:headers] << "Authorization: #{HOMEBREW_GITHUB_PACKAGES_AUTH}"
    super(url, name, version, **meta)
  end

  private

  def resolved_basename
    @resolved_basename.presence || super
  end
end

# Strategy for downloading a file from an Apache Mirror URL.
#
# @api public
class CurlApacheMirrorDownloadStrategy < CurlDownloadStrategy
  def mirrors
    combined_mirrors
  end

  private

  def combined_mirrors
    return @combined_mirrors if defined?(@combined_mirrors)

    backup_mirrors = apache_mirrors.fetch("backup", [])
                                   .map { |mirror| "#{mirror}#{apache_mirrors["path_info"]}" }

    @combined_mirrors = [*@mirrors, *backup_mirrors]
  end

  def resolve_url_basename_time_file_size(url, timeout: nil)
    if url == self.url
      super("#{apache_mirrors["preferred"]}#{apache_mirrors["path_info"]}", timeout: timeout)
    else
      super
    end
  end

  def apache_mirrors
    return @apache_mirrors if defined?(@apache_mirrors)

    json, = curl_output("--silent", "--location", "#{url}&asjson=1")
    @apache_mirrors = JSON.parse(json)
  rescue JSON::ParserError
    raise CurlDownloadStrategyError, "Couldn't determine mirror, try again later."
  end
end

# Strategy for downloading via an HTTP POST request using `curl`.
# Query parameters on the URL are converted into POST parameters.
#
# @api public
class CurlPostDownloadStrategy < CurlDownloadStrategy
  private

  def _fetch(url:, resolved_url:, timeout:)
    args = if meta.key?(:data)
      escape_data = ->(d) { ["-d", URI.encode_www_form([d])] }
      [url, *meta[:data].flat_map(&escape_data)]
    else
      url, query = url.split("?", 2)
      query.nil? ? [url, "-X", "POST"] : [url, "-d", query]
    end

    curl_download(*args, to: temporary_path, try_partial: @try_partial, timeout: timeout)
  end
end

# Strategy for downloading archives without automatically extracting them.
# (Useful for downloading `.jar` files.)
#
# @api public
class NoUnzipCurlDownloadStrategy < CurlDownloadStrategy
  def stage
    UnpackStrategy::Uncompressed.new(cached_location)
                                .extract(basename: basename,
                                         verbose:  verbose? && !quiet?)
    yield if block_given?
  end
end

# Strategy for extracting local binary packages.
#
# @api private
class LocalBottleDownloadStrategy < AbstractFileDownloadStrategy
  def initialize(path) # rubocop:disable Lint/MissingSuper
    @cached_location = path
    extend Pourable
  end
end

# Strategy for downloading a Subversion repository.
#
# @api public
class SubversionDownloadStrategy < VCSDownloadStrategy
  extend T::Sig

  def initialize(url, name, version, **meta)
    super
    @url = @url.sub("svn+http://", "")
  end

  # Download and cache the repository at {#cached_location}.
  #
  # @api public
  def fetch(timeout: nil)
    if @url.chomp("/") != repo_url || !silent_command("svn", args: ["switch", @url, cached_location]).success?
      clear_cache
    end
    super
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    time = if Version.create(Utils::Svn.version) >= Version.create("1.9")
      out, = silent_command("svn", args: ["info", "--show-item", "last-changed-date"], chdir: cached_location)
      out
    else
      out, = silent_command("svn", args: ["info"], chdir: cached_location)
      out[/^Last Changed Date: (.+)$/, 1]
    end
    Time.parse time
  end

  # @see VCSDownloadStrategy#last_commit
  # @api public
  sig { returns(String) }
  def last_commit
    out, = silent_command("svn", args: ["info", "--show-item", "revision"], chdir: cached_location)
    out.strip
  end

  private

  def repo_url
    out, = silent_command("svn", args: ["info"], chdir: cached_location)
    out.strip[/^URL: (.+)$/, 1]
  end

  def externals
    out, = silent_command("svn", args: ["propget", "svn:externals", @url])
    out.chomp.split("\n").each do |line|
      name, url = line.split(/\s+/)
      yield name, url
    end
  end

  sig {
    params(target: Pathname, url: String, revision: T.nilable(String), ignore_externals: T::Boolean,
           timeout: T.nilable(Time)).void
  }
  def fetch_repo(target, url, revision = nil, ignore_externals: false, timeout: nil)
    # Use "svn update" when the repository already exists locally.
    # This saves on bandwidth and will have a similar effect to verifying the
    # cache as it will make any changes to get the right revision.
    args = []
    args << "--quiet" unless verbose?

    if revision
      ohai "Checking out #{@ref}"
      args << "-r" << revision
    end

    args << "--ignore-externals" if ignore_externals

    args.concat Utils::Svn.invalid_cert_flags if meta[:trust_cert] == true

    if target.directory?
      command! "svn", args: ["update", *args], chdir: target.to_s, timeout: timeout&.remaining
    else
      command! "svn", args: ["checkout", url, target, *args], timeout: timeout&.remaining
    end
  end

  sig { returns(String) }
  def cache_tag
    head? ? "svn-HEAD" : "svn"
  end

  def repo_valid?
    (cached_location/".svn").directory?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    case @ref_type
    when :revision
      fetch_repo cached_location, @url, @ref, timeout: timeout
    when :revisions
      # nil is OK for main_revision, as fetch_repo will then get latest
      main_revision = @ref[:trunk]
      fetch_repo cached_location, @url, main_revision, ignore_externals: true, timeout: timeout

      externals do |external_name, external_url|
        fetch_repo cached_location/external_name, external_url, @ref[external_name], ignore_externals: true,
                                                                                     timeout:          timeout
      end
    else
      fetch_repo cached_location, @url, timeout: timeout
    end
  end
  alias update clone_repo
end

# Strategy for downloading a Git repository.
#
# @api public
class GitDownloadStrategy < VCSDownloadStrategy
  def initialize(url, name, version, **meta)
    # Needs to be before the call to `super`, as the VCSDownloadStrategy's
    # constructor calls `cache_tag` and sets the cache path.
    @only_path = meta[:only_path]

    super
    @ref_type ||= :branch
    @ref ||= "master"
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    out, = silent_command("git", args: ["--git-dir", git_dir, "show", "-s", "--format=%cD"])
    Time.parse(out)
  end

  # @see VCSDownloadStrategy#last_commit
  # @api public
  sig { returns(String) }
  def last_commit
    out, = silent_command("git", args: ["--git-dir", git_dir, "rev-parse", "--short=7", "HEAD"])
    out.chomp
  end

  private

  sig { returns(String) }
  def cache_tag
    if partial_clone_sparse_checkout?
      "git-sparse"
    else
      "git"
    end
  end

  sig { returns(Integer) }
  def cache_version
    0
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    config_repo
    update_repo(timeout: timeout)
    checkout(timeout: timeout)
    reset
    update_submodules(timeout: timeout) if submodules?
  end

  def shallow_dir?
    (git_dir/"shallow").exist?
  end

  def git_dir
    cached_location/".git"
  end

  def ref?
    silent_command("git",
                   args: ["--git-dir", git_dir, "rev-parse", "-q", "--verify", "#{@ref}^{commit}"])
      .success?
  end

  def current_revision
    out, = silent_command("git", args: ["--git-dir", git_dir, "rev-parse", "-q", "--verify", "HEAD"])
    out.strip
  end

  def repo_valid?
    silent_command("git", args: ["--git-dir", git_dir, "status", "-s"]).success?
  end

  def submodules?
    (cached_location/".gitmodules").exist?
  end

  def partial_clone_sparse_checkout?
    return false if @only_path.blank?

    Utils::Git.supports_partial_clone_sparse_checkout?
  end

  sig { returns(T::Array[String]) }
  def clone_args
    args = %w[clone]

    case @ref_type
    when :branch, :tag
      args << "--branch" << @ref
    end

    args << "--no-checkout" << "--filter=blob:none" if partial_clone_sparse_checkout?

    args << "-c" << "advice.detachedHead=false" # silences detached head warning
    args << @url << cached_location
  end

  sig { returns(String) }
  def refspec
    case @ref_type
    when :branch then "+refs/heads/#{@ref}:refs/remotes/origin/#{@ref}"
    when :tag    then "+refs/tags/#{@ref}:refs/tags/#{@ref}"
    else              default_refspec
    end
  end

  sig { returns(String) }
  def default_refspec
    # https://git-scm.com/book/en/v2/Git-Internals-The-Refspec
    "+refs/heads/*:refs/remotes/origin/*"
  end

  sig { void }
  def config_repo
    command! "git",
             args:  ["config", "remote.origin.url", @url],
             chdir: cached_location
    command! "git",
             args:  ["config", "remote.origin.fetch", refspec],
             chdir: cached_location
    command! "git",
             args:  ["config", "remote.origin.tagOpt", "--no-tags"],
             chdir: cached_location
    command! "git",
             args:  ["config", "advice.detachedHead", "false"],
             chdir: cached_location

    return unless partial_clone_sparse_checkout?

    command! "git",
             args:  ["config", "origin.partialclonefilter", "blob:none"],
             chdir: cached_location
    configure_sparse_checkout
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update_repo(timeout: nil)
    return if @ref_type != :branch && ref?

    # Convert any shallow clone to full clone
    if shallow_dir?
      command! "git",
               args:    ["fetch", "origin", "--unshallow"],
               chdir:   cached_location,
               timeout: timeout&.remaining
    else
      command! "git",
               args:    ["fetch", "origin"],
               chdir:   cached_location,
               timeout: timeout&.remaining
    end
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    command! "git", args: clone_args, timeout: timeout&.remaining

    command! "git",
             args:    ["config", "homebrew.cacheversion", cache_version],
             chdir:   cached_location,
             timeout: timeout&.remaining

    configure_sparse_checkout if partial_clone_sparse_checkout?

    checkout(timeout: timeout)
    update_submodules(timeout: timeout) if submodules?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def checkout(timeout: nil)
    ohai "Checking out #{@ref_type} #{@ref}" if @ref_type && @ref
    command! "git", args: ["checkout", "-f", @ref, "--"], chdir: cached_location, timeout: timeout&.remaining
  end

  sig { void }
  def reset
    ref = case @ref_type
    when :branch
      "origin/#{@ref}"
    when :revision, :tag
      @ref
    end

    command! "git",
             args:  ["reset", "--hard", *ref, "--"],
             chdir: cached_location
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update_submodules(timeout: nil)
    command! "git",
             args:    ["submodule", "foreach", "--recursive", "git submodule sync"],
             chdir:   cached_location,
             timeout: timeout&.remaining
    command! "git",
             args:    ["submodule", "update", "--init", "--recursive"],
             chdir:   cached_location,
             timeout: timeout&.remaining
    fix_absolute_submodule_gitdir_references!
  end

  # When checking out Git repositories with recursive submodules, some Git
  # versions create `.git` files with absolute instead of relative `gitdir:`
  # pointers. This works for the cached location, but breaks various Git
  # operations once the affected Git resource is staged, i.e. recursively
  # copied to a new location. (This bug was introduced in Git 2.7.0 and fixed
  # in 2.8.3. Clones created with affected version remain broken.)
  # See https://github.com/Homebrew/homebrew-core/pull/1520 for an example.
  def fix_absolute_submodule_gitdir_references!
    submodule_dirs = command!("git",
                              args:  ["submodule", "--quiet", "foreach", "--recursive", "pwd"],
                              chdir: cached_location).stdout

    submodule_dirs.lines.map(&:chomp).each do |submodule_dir|
      work_dir = Pathname.new(submodule_dir)

      # Only check and fix if `.git` is a regular file, not a directory.
      dot_git = work_dir/".git"
      next unless dot_git.file?

      git_dir = dot_git.read.chomp[/^gitdir: (.*)$/, 1]
      if git_dir.nil?
        onoe "Failed to parse '#{dot_git}'." if Homebrew::EnvConfig.developer?
        next
      end

      # Only attempt to fix absolute paths.
      next unless git_dir.start_with?("/")

      # Make the `gitdir:` reference relative to the working directory.
      relative_git_dir = Pathname.new(git_dir).relative_path_from(work_dir)
      dot_git.atomic_write("gitdir: #{relative_git_dir}\n")
    end
  end

  def configure_sparse_checkout
    command! "git",
             args:  ["config", "core.sparseCheckout", "true"],
             chdir: cached_location

    (git_dir/"info"/"sparse-checkout").atomic_write("#{@only_path}\n")
  end
end

# Strategy for downloading a Git repository from GitHub.
#
# @api public
class GitHubGitDownloadStrategy < GitDownloadStrategy
  def initialize(url, name, version, **meta)
    super

    return unless %r{^https?://github\.com/(?<user>[^/]+)/(?<repo>[^/]+)\.git$} =~ @url

    @user = user
    @repo = repo
  end

  def commit_outdated?(commit)
    @last_commit ||= GitHub.last_commit(@user, @repo, @ref)
    if @last_commit
      return true unless commit
      return true unless @last_commit.start_with?(commit)

      if GitHub.multiple_short_commits_exist?(@user, @repo, commit)
        true
      else
        version.update_commit(commit)
        false
      end
    else
      super
    end
  end

  sig { returns(String) }
  def default_refspec
    if default_branch
      "+refs/heads/#{default_branch}:refs/remotes/origin/#{default_branch}"
    else
      super
    end
  end

  sig { returns(String) }
  def default_branch
    return @default_branch if defined?(@default_branch)

    command! "git",
             args:  ["remote", "set-head", "origin", "--auto"],
             chdir: cached_location

    result = command! "git",
                      args:  ["symbolic-ref", "refs/remotes/origin/HEAD"],
                      chdir: cached_location

    @default_branch = result.stdout[%r{^refs/remotes/origin/(.*)$}, 1]
  end
end

# Strategy for downloading a CVS repository.
#
# @api public
class CVSDownloadStrategy < VCSDownloadStrategy
  extend T::Sig

  def initialize(url, name, version, **meta)
    super
    @url = @url.sub(%r{^cvs://}, "")

    if meta.key?(:module)
      @module = meta.fetch(:module)
    elsif !@url.match?(%r{:[^/]+$})
      @module = name
    else
      @module, @url = split_url(@url)
    end
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    # Filter CVS's files because the timestamp for each of them is the moment
    # of clone.
    max_mtime = Time.at(0)
    cached_location.find do |f|
      Find.prune if f.directory? && f.basename.to_s == "CVS"
      next unless f.file?

      mtime = f.mtime
      max_mtime = mtime if mtime > max_mtime
    end
    max_mtime
  end

  private

  def env
    { "PATH" => PATH.new("/usr/bin", Formula["cvs"].opt_bin, ENV.fetch("PATH")) }
  end

  sig { returns(String) }
  def cache_tag
    "cvs"
  end

  def repo_valid?
    (cached_location/"CVS").directory?
  end

  def quiet_flag
    "-Q" unless verbose?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    # Login is only needed (and allowed) with pserver; skip for anoncvs.
    command! "cvs", args: [*quiet_flag, "-d", @url, "login"], timeout: timeout&.remaining if @url.include? "pserver"

    command! "cvs",
             args:    [*quiet_flag, "-d", @url, "checkout", "-d", cached_location.basename, @module],
             chdir:   cached_location.dirname,
             timeout: timeout&.remaining
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    command! "cvs",
             args:    [*quiet_flag, "update"],
             chdir:   cached_location,
             timeout: timeout&.remaining
  end

  def split_url(in_url)
    parts = in_url.split(":")
    mod = parts.pop
    url = parts.join(":")
    [mod, url]
  end
end

# Strategy for downloading a Mercurial repository.
#
# @api public
class MercurialDownloadStrategy < VCSDownloadStrategy
  extend T::Sig

  def initialize(url, name, version, **meta)
    super
    @url = @url.sub(%r{^hg://}, "")
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    out, = silent_command("hg",
                          args: ["tip", "--template", "{date|isodate}", "-R", cached_location])

    Time.parse(out)
  end

  # @see VCSDownloadStrategy#last_commit
  # @api public
  sig { returns(String) }
  def last_commit
    out, = silent_command("hg", args: ["parent", "--template", "{node|short}", "-R", cached_location])
    out.chomp
  end

  private

  def env
    { "PATH" => PATH.new(Formula["mercurial"].opt_bin, ENV.fetch("PATH")) }
  end

  sig { returns(String) }
  def cache_tag
    "hg"
  end

  def repo_valid?
    (cached_location/".hg").directory?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    command! "hg", args: ["clone", @url, cached_location], timeout: timeout&.remaining
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    command! "hg", args: ["--cwd", cached_location, "pull", "--update"], timeout: timeout&.remaining

    update_args = if @ref_type && @ref
      ohai "Checking out #{@ref_type} #{@ref}"
      [@ref]
    else
      ["--clean"]
    end

    command! "hg", args: ["--cwd", cached_location, "update", *update_args], timeout: timeout&.remaining
  end
end

# Strategy for downloading a Bazaar repository.
#
# @api public
class BazaarDownloadStrategy < VCSDownloadStrategy
  extend T::Sig

  def initialize(url, name, version, **meta)
    super
    @url.sub!(%r{^bzr://}, "")
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    out, = silent_command("bzr", args: ["log", "-l", "1", "--timezone=utc", cached_location])
    timestamp = out.chomp
    raise "Could not get any timestamps from bzr!" if timestamp.blank?

    Time.parse(timestamp)
  end

  # @see VCSDownloadStrategy#last_commit
  # @api public
  sig { returns(String) }
  def last_commit
    out, = silent_command("bzr", args: ["revno", cached_location])
    out.chomp
  end

  private

  def env
    {
      "PATH"     => PATH.new(Formula["breezy"].opt_bin, ENV.fetch("PATH")),
      "BZR_HOME" => HOMEBREW_TEMP,
    }
  end

  sig { returns(String) }
  def cache_tag
    "bzr"
  end

  def repo_valid?
    (cached_location/".bzr").directory?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    # "lightweight" means history-less
    command! "bzr",
             args:    ["checkout", "--lightweight", @url, cached_location],
             timeout: timeout&.remaining
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    command! "bzr",
             args:    ["update"],
             chdir:   cached_location,
             timeout: timeout&.remaining
  end
end

# Strategy for downloading a Fossil repository.
#
# @api public
class FossilDownloadStrategy < VCSDownloadStrategy
  extend T::Sig

  def initialize(url, name, version, **meta)
    super
    @url = @url.sub(%r{^fossil://}, "")
  end

  # @see AbstractDownloadStrategy#source_modified_time
  # @api public
  sig { returns(Time) }
  def source_modified_time
    out, = silent_command("fossil", args: ["info", "tip", "-R", cached_location])
    Time.parse(out[/^uuid: +\h+ (.+)$/, 1])
  end

  # @see VCSDownloadStrategy#last_commit
  # @api public
  sig { returns(String) }
  def last_commit
    out, = silent_command("fossil", args: ["info", "tip", "-R", cached_location])
    out[/^uuid: +(\h+) .+$/, 1]
  end

  def repo_valid?
    silent_command("fossil", args: ["branch", "-R", cached_location]).success?
  end

  private

  def env
    { "PATH" => PATH.new(Formula["fossil"].opt_bin, ENV.fetch("PATH")) }
  end

  sig { returns(String) }
  def cache_tag
    "fossil"
  end

  sig { params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    command! "fossil", args: ["clone", @url, cached_location], timeout: timeout&.remaining
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    command! "fossil", args: ["pull", "-R", cached_location], timeout: timeout&.remaining
  end
end

# Helper class for detecting a download strategy from a URL.
#
# @api private
class DownloadStrategyDetector
  def self.detect(url, using = nil)
    if using.nil?
      detect_from_url(url)
    elsif using.is_a?(Class) && using < AbstractDownloadStrategy
      using
    elsif using.is_a?(Symbol)
      detect_from_symbol(using)
    else
      raise TypeError,
            "Unknown download strategy specification #{using.inspect}"
    end
  end

  def self.detect_from_url(url)
    case url
    when GitHubPackages::URL_REGEX
      CurlGitHubPackagesDownloadStrategy
    when %r{^https?://github\.com/[^/]+/[^/]+\.git$}
      GitHubGitDownloadStrategy
    when %r{^https?://.+\.git$},
         %r{^git://},
         %r{^https?://git\.sr\.ht/[^/]+/[^/]+$}
      GitDownloadStrategy
    when %r{^https?://www\.apache\.org/dyn/closer\.cgi},
         %r{^https?://www\.apache\.org/dyn/closer\.lua}
      CurlApacheMirrorDownloadStrategy
    when %r{^https?://([A-Za-z0-9\-.]+\.)?googlecode\.com/svn},
         %r{^https?://svn\.},
         %r{^svn://},
         %r{^svn\+http://},
         %r{^http://svn\.apache\.org/repos/},
         %r{^https?://([A-Za-z0-9\-.]+\.)?sourceforge\.net/svnroot/}
      SubversionDownloadStrategy
    when %r{^cvs://}
      CVSDownloadStrategy
    when %r{^hg://},
         %r{^https?://([A-Za-z0-9\-.]+\.)?googlecode\.com/hg},
         %r{^https?://([A-Za-z0-9\-.]+\.)?sourceforge\.net/hgweb/}
      MercurialDownloadStrategy
    when %r{^bzr://}
      BazaarDownloadStrategy
    when %r{^fossil://}
      FossilDownloadStrategy
    else
      CurlDownloadStrategy
    end
  end

  def self.detect_from_symbol(symbol)
    case symbol
    when :hg                     then MercurialDownloadStrategy
    when :nounzip                then NoUnzipCurlDownloadStrategy
    when :git                    then GitDownloadStrategy
    when :bzr                    then BazaarDownloadStrategy
    when :svn                    then SubversionDownloadStrategy
    when :curl                   then CurlDownloadStrategy
    when :homebrew_curl          then HomebrewCurlDownloadStrategy
    when :cvs                    then CVSDownloadStrategy
    when :post                   then CurlPostDownloadStrategy
    when :fossil                 then FossilDownloadStrategy
    else
      raise TypeError, "Unknown download strategy #{symbol} was requested."
    end
  end
end
