require 'rubygems'
require 'ditz'
require 'socket'

$:.push File.expand_path(File.join(File.dirname(__FILE__), "../camping/lib"))
require 'camping'
require 'camping/server'
require 'trollop'

Camping.goes :Sheila

class String
  def obfu; gsub(/( <.+?)@.+>$/, '\1@...>') end
  def prefix; self[0,8] end
end

hostname = begin
  Socket.gethostbyname(Socket.gethostname).first
rescue SocketError
  Socket.gethostname
end

## tweak these if you want!
CREATOR_NAME = "Sheila"
CREATOR_EMAIL = "sheila@#{hostname}"
COMMIT_COMMAND = "git commit -a -m ' * bugs/: $title$'" # currently unused
CONFIG_FN = ".ditz-config"
PLUGIN_FN = ".ditz-plugins"

Ditz::verbose = true

## config holders
class << Sheila
  attr_reader :project, :config, :storage
  def create
    ## load plugins
    plugin_fn = File.join Ditz::find_dir_containing(PLUGIN_FN) || ".", PLUGIN_FN
    Ditz::load_plugins(plugin_fn) if File.exist?(plugin_fn)

    ## load config
    config_fn = File.join Ditz::find_dir_containing(CONFIG_FN) || ".", CONFIG_FN
    Ditz::debug "loading config from #{config_fn}"
    @config = Ditz::Config.from config_fn
    @config.name = CREATOR_NAME # just overwrite these two fields
    @config.email = CREATOR_EMAIL

    ## load project
    @storage = Ditz::FileStorage.new File.join(File.dirname(config_fn), @config.issue_dir)
    @project = @storage.load
  end
end

module Sheila::Controllers
  class Index
    def get; render :index end
  end
  class TicketX
    def get sha
      @issue = Sheila.project.issues.find { |i| i.id == sha }
      render :ticket
    end
  end
  class New
    def get
      @issue = Camping::H[]
      render :editor
    end
    def post
      @input['ticket']['release'] = nil if @input['ticket']['release'] = "No release"
      @issue = Ditz::Issue.create(@input['ticket'], [Sheila.config, Sheila.project])
      @issue.log "created", Sheila.config.user, ''
      Sheila.project.add_issue @issue
      Sheila.storage.save Sheila.project
      redirect TicketX, @issue.id
    end
  end
  class Signup
    def get
      @me = User.new
      render :profile
    end
  end
  class ReleaseX
    def get num
      @release = Sheila.project.releases[num.to_i] # see docs for Views#ticket
      @created, @desc = @release.log_events[0].first, @release.log_events[0].last
      render :release
    end
  end
  class Style < R '/styles.css'
    def get
      @headers["Content-Type"] = "text/css; charset=utf-8"
      @body = Sheila::CSS
    end
  end
end

module Sheila::Views
  def layout
    html do
      head do
        title 'bugs'
        link :rel => 'stylesheet', :type => 'text/css', 
             :href => '/styles.css', :media => 'screen'
      end
      body do
        h1.header { a Sheila.project.name, :href => R(Index) }
        div.content do
          self << yield
        end
      end
    end
  end

  def index
    h2 "Open Tickets"
    p { a "Add a ticket", :href => R(New) }
    ticket_table Sheila.project.issues
  end

  def ticket_table issues, exclude = [:closed]
    table.tickets! do
      tr do
        th "ID"
        th "Title"
        th "State"
      end
      issues.sort_by { |i| i.creation_time }.reverse.each do |issue|
        unless exclude.include? issue.status
          tr do
            td.unique issue.id.prefix
            td.title  { h3 { a issue.title, :href => R(TicketX, issue.id) }
              p.about { strong("#{issue.creation_time.ago} ago") + span(" by #{issue.reporter.obfu}") } }
            td.status { issue.status.to_s }
          end
        end
      end
    end
  end

  def release
    h2 @release.name
    if @release.release_time
      h3 "Released #{@release.release_time.ago} ago"
    else
      h3 "Started #{@created.ago} ago"
    end
    div.description { dewikify @desc }
    h4 "Tickets"
    ticket_table @release.issues_from(Sheila.project)
  end

  def ticket
    h2 @issue.title
    h3 { span.unique.right @issue.id.prefix; span "started #{@issue.creation_time.ago} ago by #{@issue.reporter.obfu}" }
    div.details do
      dewikify(@issue.desc)
    end
    div.details do
      if @issue.release
        p { strong "Type: "; span @issue.type.to_s }
        ## unfortunately this next thing always raises a "bad route" if the
        ## release name has any dots or dashes in it
        #p { strong "Release: "; a @issue.release, :href => R(ReleaseX, @issue.release) }
        ## instead, we do this bad thing:
        foul = Sheila.project.releases.map { |r| r.name }.index @issue.release
        p { strong "Release: "; a @issue.release, :href => R(ReleaseX, foul) }
        p { strong "Status: "; span @issue.status.to_s }
      end
    end
    h4 "Comments"
    events @issue.log_events
  end

  def events log
    ul.events do
      log.each do |at, name, action, comment|
        li do
          div.ago "#{at.ago} ago"
          div.who name.obfu
          div.action action
          div.comment comment if comment
        end
      end
    end
  end

  def editor
    h2 "Create a New Ticket"
    form :method => 'POST', :action => R(New) do
      fieldset do
        div.required.right do
          label 'Type'
          select :name => 'ticket[type]' do
            Ditz::Issue::TYPES.each { |t| option t.to_s, :selected => @issue.type == t }
          end
        end
        div.required.right do
          label 'Component', :for => 'ticket[component]'
          select :name => 'ticket[component]' do
            Sheila.project.components.each { |c| option c.name, :selected => @issue.component == c.name }
          end
        end
        div.required do
          label 'Title', :for => 'ticket[title]'
          input :name => 'ticket[title]', :type => 'text', :value => @issue.title
        end
        div.required do
          label 'Your name & email', :for => 'ticket[reporter]'
          input :name => 'ticket[reporter]', :type => 'text'
        end
        div.required do
          label 'Release', :for => 'ticket[release]'
          select :name => 'ticket[release]' do
            Sheila.project.releases.each { |rel| option rel.name, :selected => @issue.release == rel.name }
            option "No release", :selected => @issue.release == nil
          end
        end
        div.required do
          label 'Description', :for => 'ticket[desc]'
          textarea @issue.desc, :name => 'ticket[desc]'
        end
        if Sheila.project.components.size > 1
          label 'Component', :for => 'ticket[component]'
          select :name => 'ticket[component]' do
            Sheila.project.components.each do |c|
              option c.name, :selected => @issue.component == c.name
            end
          end
        end
        div.buttons do
          input :name => 'Save', :value => 'Save', :type => 'submit'
        end
      end
    end
  end

  def dewikify(str)
    str.split(/\s*?(\{{3}(?:.+?)\}{3})|\n\n/m).map do |para|
      next if para.empty?
      if para =~ /\{{3}(?:\s*\#![^\n]+)?(.+?)\}{3}/m
        self << 
          pre($1).to_s.gsub(/ +#=\&gt;.+$/, '<span class="outputs">\0</span>').
            gsub(/ +# .+$/, '<span class="comment">\0</span>')
      else
        case para
        when /\A\* (.+)/m
          ul { $1.split(/^\* /).map { |x| li x } }
        when /\A==== (.+) ====/
          h4($1)
        when /\A=== (.+) ===/
          h3($1)
        when /\A== (.+) ==/
          h2($1)
        when /\A= (.+) =/
          h1($1)
        else
          p(para)
        end
        # txt.gsub(/`(.+?)`/m, '<code>\1</code>').gsub(/\[\[BR\]\]/i, '<br />').
        #   gsub(/'''(.+?)'''/m, '<strong>\1</strong>').gsub(/''(.+?)''/m, '<em>\1</em>').   
        #   gsub(/\[\[(\S+?) (.+?)\]\]/m, '<a href="\1">\2</a>').
        #   gsub(/\(\!\)/m, '<img src="/static/exclamation.png" />').
        #   gsub(/\!\\(\S+\.png)\!/, '<img class="inline" src="/static/\1" />').
        #   gsub(/\!(\S+\.png)\!/, '<img src="/static/\1" />')
      end
    end
  end
end

Sheila::CSS = <<END
body { font: 0.75em/1.5 'Lucida Grande', sans-serif; color: #333; }
* { margin: 0; padding: 0; }
a { text-decoration: none; color: blue; }
a:hover { text-decoration: underline; }
h2 { font-size: 36px; font-weight: normal; line-height: 120%; }

label {
  display: block;
}
h1.header {
  background-color: #660;
  margin: 0; padding: 4px 16px;
  width: 620px;
  margin: 0 auto;
}
h1.header a {
  color: #fef;
}
fieldset {
  border: none;
}
h3.field {
  display: inline;
  background-color: #eee;
  padding: 4px;
}
div.required {
  margin: 6px 0;
}
div.buttons {
  border-top: solid 1px #eee;
  padding: 6px 0;
}
input {
  padding: 4px;
}
div.required input,
div.required select {
  width: 200px;
  padding: 4px;
}
.right {
  float: right;
}
div.right {
  margin-right: 120px;
}
textarea {
  margin-top: 4px;
  width: 100%;
  padding: 4px;
  width: 540px;
  height: 260px;
}

#tickets {
  margin: 20px 0;
}
#tickets td {
  font-size: 14px;
  padding: 5px;
  border-bottom: solid 1px #eee;
}
#tickets th {
  font-size: 14px;
  padding: 5px;
  border-bottom: solid 3px #ccc;
}
#tickets td .about {
  font-size: 11px;
}
div.content {
  padding: 10px;
  width: 620px;
  margin: 0 auto;
}

div.details {
  border-top: solid 1px #eee;
  margin: 10px 0;
  padding: 16px 0;
}
h4 {
  color: white;
  background-color: #ccc;
  padding: 2px 6px;
}
ul.events li {
  border-bottom: solid 1px #eee;
  list-style: none;
  padding: 10px 0;
}
div.description {
  padding: 10px 20px;
}
div.ago {
  font-weight: bold;
}
div.action {
  color: #a09;
}
ul.events div.ago,
ul.events div.who {
  display: block;
  padding-right: 20px;
  float: left;
}
ul.events div.comment {
  color: #777;
}
.unique {
  color: #999;
}
END

##### EXECUTION STARTS HERE #####
opts = Trollop::options do
  version "sheila (ditz version #{Ditz::VERSION})"

  opt :verbose, "Verbose output", :default => false
  opt :host, "Host on which to run", :default => "0.0.0.0"
  opt :port, "Port on which to run", :default => 1234
  opt :server, "Camping server type to use (mongrel, webrick, console)", :default => "mongrel"
end

if opts[:server] == "mongrel"
  begin
    require 'mongrel'
  rescue LoadError
    $stderr.puts "!! could not load mongrel. Falling back to webrick."
    opts[:server] = "webrick"
  end
end

## next part stolen from camping/server.rb.
## all fancy reloading viciously stripped out.
handler, conf = case opts[:server]
when "console"
  ARGV.clear
  IRB.start
  exit
when "mongrel"
  puts "** Starting Mongrel on #{opts[:host]}:#{opts[:port]}"
  [Rack::Handler::Mongrel, {:Port => opts[:port], :Host => opts[:host]}]
when "webrick"
  [Rack::Handler::WEBrick, {:Port => opts[:port], :BindAddress => opts[:host]}]
end

Sheila.create
rapp = Rack::Lint.new Sheila
rapp = Camping::Server::XSendfile.new rapp
rapp = Rack::ShowExceptions.new rapp
handler.run rapp, conf
