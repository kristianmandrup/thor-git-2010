require 'thor/group'

module Git
  class Project < Thor::Group
    include Thor::Actions

    # Define arguments and options
    argument :name # :desc, :required, :optional, :type (:string, :hash, :array, :numeric), :default, :banner

    class_option :github,       :type => :boolean, :aliases => '-g',  :default => false     
    class_option :push,         :type => :boolean, :aliases => '-p',  :default => false     
    class_option :skip_license, :type => :boolean, :aliases => '-l',  :default => false     
    class_option :message,      :type => :string,  :aliases => '-m',  :default => 'Initial commit'
    class_option :return,       :type => :boolean, :aliases => '-r',  :default => false       

    def self.source_root
      # use line below when deploying the task
      template_path(__FILE__)
      # local_template_path(__FILE__) # tries ROOT/templates and then ROOT/lib/templates
    end

    def create_root
      if !File.directory?(name)
        self.destination_root = File.expand_path(name, destination_root)
        empty_directory '.'
        FileUtils.cd(destination_root)
      end
    end

    def initial_commit
      git :init

      template 'README.markdown'
      template 'MITLICENSE' if !options[:skip_license]

      git :add => '.'
      git :commit => "-a -m '#{options[:message]}'"
    end

    def github
      return false if !options[:github]
      git :remote => "add origin git@github.com:$GITHUB_NAME/$name.git"
    end
    
    def github_push
      return false if !options[:push]
      git :push => 'origin master'
    end 

    def return_after
      run "cd .." if options[:return]
    end
    
    protected
      include Base
    
  end # class

  # Create a new branch off master, named NAME
  class Open < Thor::Group
    include Thor::Actions

    argument :name, :type => :string, :optional => true

    def execute
      newbranch = name if name && !name.empty?
      newbranch ||= begin
        require "readline"
        print "* Name your branch: "
        Readline.readline.chomp
      end
      branch = git_branch
      if git_branches.include?(newbranch)
        if newbranch == branch
          puts "* Already on branch \"#{newbranch}\""
        else
          puts "* Switching to existing branch \"#{newbranch}\""
          git_checkout(newbranch, :silent => true)
          system "git log --pretty=oneline --abbrev-commit master..HEAD"
        end
        exit(0)
      end
      unless branch == "master"
        puts "* Switching to master"
        git_checkout("master")
      end
      git_checkout(newbranch, :create_branch => true)
      unless $?.exitstatus.zero?
        puts "* Couldn't create branch #{newbranch}, switching back to #{branch}"
        git_checkout(branch)
        exit(1)
      end
      exit(0)
    end  
    
    protected
      include Base
    
  end

  # Delete the current branch and switch back to master
  class Close < Thor::Group
    include Thor::Actions

    argument :name, :type => :string, :optional => true

    def execute
      branch = name if name && !name.empty?
      branch ||= git_branch
      current = git_branch
      if branch == "master"
        $stderr.puts "* Cannot delete master branch"
        exit(1)
      end
      if current == branch
        puts "* Switching to master"
        git_checkout("master")
      end
      puts "* Deleting branch #{branch}"
      git_branch(branch, :delete => true)
      if $?.exitstatus == 1
        $stderr.puts "* Branch #{branch} isn't a strict subset of master, quitting"
        git_checkout(current)
        exit(1)
      end
      git_checkout(current) unless current == branch
      exit(0)
    end  
    
    protected
      include Base
    
  end

  # Merge the current branch into the master branch.
  class Fold < Thor::Group
    include Thor::Actions

    def execute
      branch = git_branch
      if branch == "master"
        $stderr.puts "* Cannot fold master branch"
        exit(1)
      end
      puts "* Switching to master"
      git_checkout("master")
      puts "* Merging #{branch}"
      @merge_flags ||= {}
      git_merge(branch, @merge_flags)
      if $?.exitstatus == 1
        $stderr.puts "* Merge had errors -- see to your friend"
        exit(1)
      end
      puts "* Switching to #{branch}"
      git_checkout(branch)
    end   
    
    protected
      include Base
    
  end

  # Converts an existing Subversion Repo into a Git Repository
  class Ify < Thor::Group
    include Thor::Actions

    class_option :stdlayout, :type => :boolean

    def execute
      unless File.directory?("./.svn")
        $stderr.puts "This task can only be executed in an existing working copy! (No .svn-Folder found)"
        exit(1)
      end
      svnurl = `svn info`.grep(/^URL:/).first.gsub("URL: ", "").chomp

      # Remove "trunk" from the svnurl if we use the stdlayout option
      svnurl.slice!(-5, 5) if options[:stdlayout] && svnurl =~ /trunk$/

      project = "../#{File.basename(Dir.pwd)}.git"
      puts(cmd = "git svn clone #{"--stdlayout" if options[:stdlayout]} #{svnurl} #{project}")
      `#{cmd}`
    end

    protected
      include Base
    
  end

  # Push local commits into the remote repository
  class Push < Thor::Group
    include Thor::Actions

    def execute
      git_stash do
        puts "* Pushing changes..."
        git_push
        branch = git_branch
        if branch != "master"
          git_checkout("master")
          puts "* Porting changes into master"
          git_rebase
          git_checkout(branch)
        end
      end
      
      protected
        include Base
      
    end
  end

  # Squash the current branch into the master branch.
  class Squash < Thor::Group
    include Thor::Actions

    

    def execute
      @merge_flags = {:squash => true}
      fold
    end
    
    protected
      include Base
    
  end

  # Pull new commits from the repository
  class Update < Thor::Group
    include Thor::Actions

    def execute
      git_stash do
        branch = git_branch
        if branch == "master"
          switch = false
        else
          switch = true
          git_checkout("master")
          puts "* Switching back to master..."
        end
        puts "* Pulling in new commits..."
        git_fetch
        git_rebase
        if switch
          puts "* Porting changes into #{branch}..."
          git_checkout(branch)
          git_rebase("master")
        end
      end
    end 
    
    protected
      include Base
    
  end

  # Update all branches
  class All < Thor::Group
    include Thor::Actions

    def exec
      git_stash do
        branch = git_branch
        switch = true
        git_branches.each do |b|
          puts "* Updating branch #{b}"
          begin
            git_rebase(b)
          rescue GitRebaseError => e
            puts "* Couldn't rebase #{b}, aborting so you can clean it up"
            switch = false
            break
          end
        end
        git_checkout(branch) if switch
      end
    end
    
    protected
      include Base
    
  end


  module Base  
    def git_branch(what = nil, opts = {})
      # If no name is given, return the name of the current branch
      return `git branch`.grep(/^\*/).first.strip[(2..-1)] if what.nil?

      delete = opts[:delete] ? "-d" : ""
      force_delete = opts[:force_delete] ? "-D" : ""

      `git branch #{delete} #{force_delete} #{what}`
      assert_branch_delete_succeeded(what)
    end

    def git_branches
      `git branch`.to_a.map { |b| b[(2..-1)].chomp }
    end

    def git_merge(what, opts = {})
      squash = opts[:squash] ? "--squash" : ""

      `git merge #{squash} #{what}`
    end

    def git?
      `git status`
      $?.exitstatus != 128
    end

    def git_stash
      `git diff-files --quiet`
      if $?.exitstatus == 1
        stash = true
        clear = (`git stash list`.scan("\n").size == 0)
        puts "* Saving changes..."
        `git stash save`
      else
        stash = false
      end
      begin
        yield
      rescue => e
        puts "* Encountered an error (#{e}), backing out..."
      ensure
        if stash
          puts "* Applying changes..."
          `git stash apply`
          `git stash clear` if clear
        end
      end
    end

    def git_checkout(what = nil, opts = {})
      silent = opts[:silent] ? "-q" : ""
      create_branch = opts[:create_branch] ? "-b" : ""

      branch = git_branch
      `git checkout #{silent} #{create_branch} #{what}` if branch != what
      if block_given?
        yield
        `git checkout #{silent} #{create_branch} #{branch}` if branch != what
      end
    end

    def git_fetch
      `git#{" svn" if git_svn?} fetch`
    end

    def assert_command_succeeded(*args)
      raise(*args) unless $?.exitstatus == 0
    end

    def assert_rebase_succeeded(what = nil)
      assert_command_succeeded(GitRebaseError, "conflict while rebasing branch #{what}")
    end

    def assert_branch_delete_succeeded(what = nil)
      assert_command_succeeded(GitBranchDeleteError, "branch #{what} could not be deleted")
    end

    def git_rebase(what = nil)
      if git_svn?
        git_checkout(what) do
          `git svn rebase --local`
          assert_rebase_succeeded(what)
        end
      else
        `git rebase origin/master #{what}`
        assert_rebase_succeeded(what)
      end
    end

    def git_push
      git_svn? ? (`git svn dcommit`) : (`git push`)
    end

    def chroot
      # store cwd
      dir = Dir.pwd

      # find .git
      until File.directory?('.git') || File.expand_path('.') == '/'
        Dir.chdir('..')
      end
      is_git = File.directory?('.git')

      raise NoRepositoryError, "No repository found containing #{dir}" unless is_git
    end

    def git_svn?
      chroot
      (not File.readlines(".git/config").grep(/^\[svn-remote "svn"\]\s*$/).empty?)
    end
  end
end
