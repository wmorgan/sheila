require 'rubygems'
require 'camping'
require 'camping/session'
require 'digest/sha1'
require 'ditz'

Camping.goes :Sheila

Sheila::DIR = "/home/why/svn/shoes/bugs"
Sheila::COMMIT = "git commit -a -m ' * bugs/: $title$'"

Sheila::CONFIG = Ditz::Config.new
Sheila::CONFIG.name = 'Sheila'
Sheila::CONFIG.email = 'sheila@rubyforge.org'

module Sheila; include Camping::Session end

class << Sheila
  attr_reader :project
  def obfu name
    name.gsub(/( <.+?)@.+>$/, '\1@...>')
  end
  def reporter; '_why <why@whytheluckystiff.net>' end
  def create; load_project; end
  def load_project
    @project = Ditz::Project.from File.join(Sheila::DIR, "project.yaml")
    issue_glob = File.join(Sheila::DIR, "issue-*.yaml")
    @project.issues = Dir[issue_glob].
      map { |fn| Ditz::Issue.from fn }.
      sort_by { |issue| issue.sort_order }
    @project.validate!
    @project.issues.each { |p| p.project = @project}
    @project.assign_issue_names!
  end
end

def ISSUE_TO_FN i; "issue-#{i.id}.yaml" end

class Ditz::ModelObject
  def self.create hsh
    o = self.new
    args = [Sheila::CONFIG, Sheila.project]
    @fields.each do |name, field_opts|
      val =
        if field_opts[:ask] == false
          if field_opts[:generator].is_a? Proc
            field_opts[:generator].call *args
          elsif field_opts[:generator]
            o.send field_opts[:generator], *args
          else
            field_opts[:default] || (field_opts[:multi] ? [] : nil)
          end
        else
          hsh[name.to_s]
        end
      o.send("#{name}=", val)
    end
    o
  end
end

class Ditz::Issue
  def self.create hsh
    hsh['type'] = 
      if ['bugfix', 'feature'].include? hsh['type']
        hsh['type'].intern
      end
    hsh['reporter'] = Sheila.reporter
    hsh['component'] ||= Sheila.project.components.first.name
    super hsh
  end
  def reporter_name
    Sheila.obfu(reporter)
  end
  def uniqid; id[0,6] end
end

def sha1 str; SHA1::Digest.hexdigest str end

module Sheila::Models
  class User < Base
    validates_presence_of :username
    validates_uniqueness_of :username
    validates_format_of :username, :with => /^[\w\- ]+$/i, 
      :message => 'must be letters, numbers, spaces, dashes only.', :on => :create
    validates_presence_of :password
    validates_confirmation_of :password, :on => :create
    validates_presence_of :email
    validates_format_of :email, :with => /^([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})$/i, :on => :create

    before_save :cipher_password!
    private
      def cipher_password!
        unless password.to_s =~ /^[\dabcdef]{32}$/
          write_attribute("password", sha1(password))
          @password_confirmation = sha1(@password_confirmation) if @password_confirmation
        end
      end
  end

  class InitialSetup < V 1.0
    def self.up
      create_table :sheila_users do |t|
        t.column :id, :integer, :null => false
        t.column :username, :string, :limit => 25, :null => false
        t.column :password, :string, :limit => 40, :null => false
        t.column :email,    :string, :limit => 255
        t.column :github,   :string, :limit => 255
        t.column :created_at, :datetime
        t.column :updated_at, :datetime
      end
    end
    def self.down
      drop_table :sheila_users
    end
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
      @issue = Ditz::Issue.create(@input['ticket'])
      @issue.log "created", Sheila::CONFIG.user, ''
      Sheila.project.add_issue @issue
      Sheila.project.assign_issue_names!
      @issue.pathname = File.join Sheila::DIR, ISSUE_TO_FN(@issue)
      @issue.project = Sheila.project
      @issue.save! @issue.pathname
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
    def get name
      @release = Sheila.project.release_for name
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
    ticket_table Sheila.project.issues
    p { a "New ticket", :href => R(New) }
  end

  def ticket_table issues, exclude = [:closed]
    table.tickets! do
      tr do
        th "ID"
        th "Title"
        th "State"
      end
      issues.reverse.each do |issue|
        unless exclude.include? issue.status
          tr do
            td.unique issue.uniqid
            td.title  { h3 { a issue.title, :href => R(TicketX, issue.id) }
              p.about { strong("#{issue.creation_time.ago} ago") + span(" by #{issue.reporter_name}") } }
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
    h3 { span.unique.right @issue.uniqid; span "started #{@issue.creation_time.ago} ago by #{@issue.reporter_name}" }
    div.details do
      dewikify(@issue.desc)
    end
    div.details do
      if @issue.release
        p { strong "Type: "; span @issue.type.to_s }
        p { strong "Release: "; a @issue.release, :href => R(ReleaseX, @issue.release) }
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
          div.who Sheila.obfu(name)
          div.action action
          div.comment comment if comment
        end
      end
    end
  end

  def sel bool
    bool ? [:selected => true] : []
  end

  def editor
    h2 "Create a New Ticket"
    form :method => 'POST', :action => R(New) do
      fieldset do
        div.required.right do
          label 'Type'
          select :name => 'ticket[type]' do
            option 'feature', *sel(@issue.type == :feature)
            option 'bugfix',  *sel(@issue.type == :bugfix)
          end
        end
        div.required do
          label 'Summary', :for => 'ticket[title]'
          input :name => 'ticket[title]', :type => 'text', :value => @issue.title
        end
        div.required do
          label 'Reporter', :for => 'ticket[reporter]'
          h3.field Sheila.reporter
        end
        div.required do
          label 'Description', :for => 'ticket[desc]'
          textarea @issue.desc, :name => 'ticket[desc]'
        end
        if Sheila.project.components.size > 1
          label 'Component', :for => 'ticket[component]'
          select :name => 'ticket[component]' do
            Sheila.project.components.each do |c|
              option c.name, *sel(@issue.component == c)
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
