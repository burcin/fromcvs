require 'rcsfile'
require 'find'
require 'md5'
require 'rbtree'


module RevSort
  attr_accessor :max_date

  # we sort revs on branch, author, log, date
  def <=>(rhs)
    r = _cmp(rhs)
    return r if r != 0

    def cmp_dates(d, l, h)
      l -= 180
      h += 180
      if d.between?(l, h)
        return 0
      else
        return d - l
      end
    end

    if @max_date
      return - cmp_dates(rhs.date, @date, @max_date)
    else
      return cmp_dates(@date, rhs.date, rhs.max_date || rhs.date)
    end
  end

  def _cmp(rhs)
    ls = @log
    rs = rhs.log
    r = ls <=> rs
    return r if r != 0

    ls = @author
    rs = rhs.author
    r = ls <=> rs
    return r if r != 0

    ls = self.syms
    rs = rhs.syms

    if !ls && !rs || (ls or []) & (rs or [])
      r = 0
    else
      r = (ls or []) <=> (rs or [])
    end
    r
  end
end

class RCSFile::Rev
  attr_accessor :file, :rcsfile
  attr_accessor :syms, :author, :branches, :state, :rev, :next
  attr_accessor :action, :link, :branch_from

  include RevSort

  def branch
    @rev[0..@rev.rindex('.')-1]
  end

  def branch_level
    (@rev.count('.') - 1) / 2
  end
end


class Repo
  class Set
    attr_accessor :author, :date, :ignore, :branch_from, :branch_level
    attr_accessor :branch
    attr_accessor :log
    attr_accessor :max_date
    attr_accessor :ary

    include RevSort

    def initialize
      @ary = []
      @ignore = true
      @branch_level = -1
      @syms = {}
    end

    def <<(rev)
      if not @author
        @author = rev.author
        @log = rev.log
        @date = rev.date
        @max_date = rev.date
      end

      add_syms(rev.syms)

      rev.log = @log    # save memory

      if @date > rev.date
        @date = rev.date
      end
      if @max_date < rev.date
        @max_date = rev.date
      end
      if rev.branch_level > @branch_level
        @branch_from = rev.branch_from
        @branch_level = rev.branch_level
      end
      ignore = rev.action == :ignore
      @ignore &&= ignore

      @ary << rev unless ignore
    end

    def add_syms(syms)
      return unless syms

      syms.each do |sym|
        @syms[sym] = sym
      end
    end

    def syms
      @syms.keys
    end

    def split_branch(branch)
      new_set = self.dup
      new_set.branch = branch
      new_set.ary = @ary.dup

      changed = false
      new_set.ary.delete_if do |rev|
        if branch
          if !rev.syms || !rev.syms.include?(branch)
            changed = true
          end
        else
          if rev.syms
            changed = true
          end
        end
      end

      return new_set if not changed

      # Okay, something changed, so finish up the fields.
      # We keep the same time like the original changeset to prevent
      # time warps for now.

      # XXX change me when we start keeping ignored revs
      new_set.ignore = true if @ary.empty?

      # Recalc branch pos
      new_set.branch_level = -1
      new_set.ary.each do |rev|
        if rev.branch_level > new_set.branch_level
          new_set.branch_from = rev.branch_from
          new_set.branch_level = rev.branch_level
        end
      end

      new_set
    end
  end

  class BranchPoint
    attr_accessor :name
    attr_accessor :level, :from
    attr_accessor :files, :revs
    attr_reader :state
    attr_accessor :create_date

    STATE_HOLDOFF = 0
    STATE_MERGE = 1
    STATE_BRANCHED = 2

    def initialize(level=-1, from=nil)
      @level = level
      @from = from
      @files = {}
      @state = STATE_HOLDOFF
      @create_date = Time.at(0)
    end

    def update(bp)
      if @level < bp.level
        @level = bp.level
        @from = bp.from
      end
    end

    def holdoff?
      @state == STATE_HOLDOFF
    end

    def merge?
      @state == STATE_MERGE
    end

    def branched?
      @state == STATE_BRANCHED
    end

    def state_transition(dest)
      case dest
      when :created
        @state = STATE_MERGE if holdoff?
      when :branched
        @state = STATE_BRANCHED if merge?
      end
    end
  end

  class TagExpander
    def initialize(cvsroot)
      @cvsroot = cvsroot
      @keywords = {}
      expandkw = []
      self.methods.select{|m| m =~ /^expand_/}.each do |kw|
        kw[/^expand_/] = ''
        @keywords[kw] = kw
      end

      configs = %w{config options}
      begin
        until configs.empty? do
          File.foreach(File.join(@cvsroot, 'CVSROOT', configs.shift)) do |line|
            if m = /^\s*(?:LocalKeyword|tag)=(\w+)(?:=(\w+))?/.match(line)
              @keywords[m[1]] = m[2] || 'Id'
            elsif m = /^\s*(?:KeywordExpand|tagexpand)=(e|i)(\w+(?:,\w+)*)?/.match(line)
              inc = m[1] == 'i'
              keyws = (m[2] || '').split(',')
              if inc
                expandkw = keyws
              else
                expandkw -= keyws
              end
            end
          end
        end
      rescue Errno::EACCES, Errno::ENOENT
        retry
      end

      if expandkw.empty?
        # produce unmatchable regexp
        @kwre = Regexp.compile('$nonmatch')
      else
        @kwre = Regexp.compile('\$('+expandkw.join('|')+')(?::[^$]*)?\$')
      end
    end

    def expand!(str, mode, rev)
      str.gsub!(@kwre) do |s|
        m = @kwre.match(s)    # gsub passes String, not MatchData
        case mode
        when 'o', 'b'
          s
        when 'k'
          "$#{m[1]}$"
        when 'kv', nil
          "$#{m[1]}: "  + send("expand_#{@keywords[m[1]]}", rev) + ' $'
        else
          s
        end
      end
    end

    def expand_Author(rev)
      rev.author
    end

    def expand_Date(rev)
      rev.date.strftime('%Y/%m/%d %H:%M:%S')
    end

    def _expand_header(rev)
      " #{rev.rev} " + expand_Date(rev) + " #{rev.author} #{rev.state}"
    end

    def expand_CVSHeader(rev)
      rev.rcsfile + _expand_header(rev)
    end

    def expand_Header(rev)
      File.join(@cvsroot, rev.rcsfile) + _expand_header(rev)
    end

    def expand_Id(rev)
      File.basename(rev.rcsfile) + _expand_header(rev)
    end

    def expand_Name(rev)
      if rev.syms
        rev.syms[0]
      else
        ""
      end
    end

    def expand_RCSfile(rev)
      File.basename(rev.rcsfile)
    end

    def expand_Revision(rev)
      rev.rev
    end

    def expand_Source(rev)
      File.join(@cvsroot, rev.rcsfile)
    end

    def expand_State(rev)
      rev.state.to_s
    end
  end

  attr_reader :sets, :sym_aliases

  def initialize(cvsroot, modul, status=nil)
    @status = status || lambda {|m|}
    @cvsroot = cvsroot.dup
    while @cvsroot.chomp!(File::SEPARATOR) do end
    @modul = modul.dup
    while @modul.chomp!(File::SEPARATOR) do end
    @path = File.join(@cvsroot, @modul)
    @expander = TagExpander.new(cvsroot)
  end

  def _normalize_path(f)
    f = f[@path.length+1..-1] if f.index(@path) == 0
    f = f[0..-3] if f[-2..-1] == ',v'
    fi = File.split(f)
    fi[0] = File.dirname(fi[0]) if File.basename(fi[0]) == 'Attic'
    fi.delete_at(0) if fi[0] == '.'
    return File.join(fi)
  end

  def scan(from_date=Time.at(0), filelist=nil)
    # Handling of repo surgery
    if filelist
      @known_files = []
      filelist.each {|v| @known_files[v] = true}
      @added_files = []
    end

    # at the expense of some cpu we normalize strings through this
    # hash so that each distinct string only is present one time.
    norm_h = {}

    # branchlists is a Hash mapping parent branches to a list of BranchPoints
    @branchlists = Hash.new {|h, k| h[k] = []}
    @branchpoints = Hash.new {|h, k| h[k] = BranchPoint.new}
    @birthdates = {}
    @sym_aliases = Hash.new {|h, k| h[k] = [k]}
    sets = MultiRBTree.new

    # branchrevs is a Hash mapping branches to the branch start revs
    branchrevs = Hash.new {|h, k| h[k] = []}

    lastdir = nil
    Find.find(@path) do |f| begin
      next if f[-2..-1] != ',v'
      next if File.directory?(f)

      dir = File.dirname(f)
      if dir != lastdir
	@status.call(dir)
	lastdir = dir
      end

      nf = _normalize_path(f)
      rcsfile = f[@cvsroot.length+1..-1]

      if @known_files and not @known_files.member?(nf)
        appeared = true
      else
        appeared = false
      end
      if File.mtime(f) < from_date and not appeared
        next
      end

      rh = {}
      RCSFile.open(f) do |rf|
        trunkrev = nil    # "rev 1.2", when the vendor branch was overwritten

        # We reverse the branches hash
        # but as there might be more than one tag
        # pointing to the same branch, we have to
        # create value arrays.
        # At the same time we ignore any non-branch tag
        sym_rev = {}
        rf.symbols.each_pair do |k, v|
          vs = v.split('.')
          vs.delete_at(-2) if vs[-2] == '0'
          next unless vs.length % 2 == 1 && vs.length > 1
          sym_rev[vs] ||= []
          sym_rev[vs].push(norm_h[k] ||= k)
        end
        sym_rev.each_value do |sl|
          next unless sl.length > 1

          # record symbol aliases, merge with existing
          sl2 = sl.dup
          sl.each do |s|
            sl2 += @sym_aliases[s]
          end
          sl2.uniq!
          sl2.each {|s| @sym_aliases[s].replace(sl2)}
        end

	rf.each_value do |rev|
	  rh[rev.rev] = rev

	  # for old revs we don't need to pimp up the fields
	  # because we will drop it soon anyways
	  #next if rev.date < from_date

	  rev.file = nf
          rev.rcsfile = rcsfile
          if rev.branch_level > 0
            branch = rev.rev.split('.')[0..-2]
            rev.syms = sym_rev[branch]
          end
	  rev.log = MD5.md5(rf.getlog(rev.rev)).digest
	  rev.author = norm_h[rev.author] ||= rev.author
	  rev.rev = norm_h[rev.rev] ||= rev.rev
	  rev.next = norm_h[rev.next] ||= rev.next
	  rev.state = rev.state.intern

          # the quest for trunkrev only happens on trunk (duh)
          if rev.branch_level == 0
            if rev.rev != '1.1'
              trunkrev = rev if not trunkrev or trunkrev.date > rev.date
            end
          end
	end

        # Branch handling
        # Unfortunately branches can span multiple changesets.  To fix this,
        # we collect the list of branch revisions (revisions where branch X
        # branches from) per branch.
        # When committing revisions, we hold off branching (and record the
        # files) until we are about to change a file on the parent branch,
        # which should already exist in the child branch, or until we are about
        # to commit the first revision to the child branch.  
        # After this, we merge each branch revision to the branch until the
        # list is empty.
        sym_rev.each do |rev, sl|
          next if rev == ['1', '1', '1']

          branchrev = rev[0..-2].join('.')
          br = rh[branchrev]
          if not br
            $stderr.puts "#{f}: branch symbol `#{sl[0]}' has dangling revision #{branchrev}"
            next
          end

          # Add this rev unless:
          # - the branch rev is dead (no use adding a dead file)
          # - the first rev "was added on branch" (will be ignored later)
          next if br.state == :dead
          # get first rev of branch
          frev = rh[br.branches.find {|r| r.split('.')[0..-2] == rev}]
          next if frev && frev.date == br.date && frev.state == :dead

          branchrevs[sl[0]] << br
        end

        # What we need to do to massage the revs correctly:
        # * branch versions need action "branch" and a name assigned
        # * branch versions without a named branch need to be ignored
        # * if the first rev on a level 1-branch/1.1 is "dead", ignore this rev
        # * if we are on a branch
        #   - all trunk revs *above* the branch point are unnamed and
        #     need to be ignored
        #   - all main branch revisions need to be merged
        #   - all branch revisions leading to the main branch need to be merged
        # * if there is a vendor branch
        #   - all vendor revisions older than "rev 1.2" need to be merged
        #   - rev 1.1 needs to be ignored if it happened at the vendor branch time
        #

        # special verndor branch handling:
        if rh.has_key?('1.1.1.1')
          if rf.branch == '1.1.1'
            trunkrev = nil
          end

          # If the file was added only on the vendor branch, 1.2 is "dead", so ignore
          # those revs completely
          if trunkrev and trunkrev.next == '1.1' and
                trunkrev.state == :dead and trunkrev.date == rh['1.1'].date
            trunkrev.action = :ignore
            rh['1.1'].action = :ignore
          end

          # some imports are without vendor symbol.  just fake one up then
          vendor_sym = nil
          if not sym_rev[['1','1','1']]
            vendor_sym = ['FIX_VENDOR']
          end

          # chop off all vendor branch versions since HEAD left the branch
          # of course only if we're not (again) on the branch
          rev = rh['1.1.1.1']
          while rev
            if !trunkrev || rev.date < trunkrev.date
              rev.action = :vendor_merge
            else
              rev.action = :vendor
            end
            if vendor_sym
              rev.syms ||= vendor_sym
            end
            rev = rh[rev.next]
          end

          # actually this 1.1 thing is totally in our way, because 1.1.1.1 already
          # covers everything.
          # oh WELL.  old CVS seemed to add a one-second difference
          if (0..1) === rh['1.1.1.1'].date - rh['1.1'].date
            rh['1.1'].action = :ignore
          end
        end

        # Handle revs on tunk, when we are actually using a branch as HEAD
        if rf.branch
          brsplit = rf.branch.split('.')
          brrev = brsplit[0..1].join('.')

          rev = rh[rf.head]
          while rev.rev != brrev
            rev.action = :ignore
            rev = rh[rev.next]
          end
        end

        if rf.branch and rf.branch != '1.1.1'
          level = 1
          loop do
            brrev = brsplit[0..(2 * level)]
            rev = rev.branches.find {|b| b.split('.')[0..(2 * level)] == brrev}
            rev = rh[rev]

            break if brrev.join('.') == rf.branch

            brrev = brsplit[0..(2 * level + 1)].join('.')
            while rev.rev != brrev
              rev.action = :branch_merge
              rev = rh[rev.next]
            end
            level += 1
          end

          while rev
            rev.action = :branch_merge
            rev = rh[rev.next]
          end
        end

        rh.each_value do |rev|
          if rev.branch_level > 0
            # if it misses a name, ignore
            if not rev.syms
              rev.action = :ignore
            else
              level = rev.branch_level
              if level == 1
                br = nil
              else
                # determine the branch we branched from
                br = rev.rev.split('.')[0..-3]
                # if we "branched" from the vendor branch
                # we effectively are branching from trunk
                if br[0..-2] == ['1', '1', '1']
                  br = nil
                else
                  br = rh[br.join('.')]

                  # the parent branch doesn't have a name, so we don't know
                  # where to branch off in the first place.
                  # I'm not sure what to do exactly, but for now hope that
                  # another file will still have the branch name.
                  if not br.syms
                    rev.action ||= :branch
                    next
                  end
                  br = br.syms[0]
                end
              end

              bpl = @branchpoints[rev.syms[0]]
              bpl.update(BranchPoint.new(level, br))
            end
            rev.action ||= :branch
          end

          rev.branches.each do |r|
            r = rh[r]
            r.link = rev.rev

            # is it "was added on branch" ...?
            if r.state == :dead and rev.date == r.date
              r.action = :ignore
            end
          end
        end

        # it was added on a different branch!
        rev = rh['1.1']
        if rev and rev.state == :dead     # don't laugh, some files start with 1.2
          rev.action = :ignore
        end

        # record when the file was introduces, we need this later
        # to check if this file even existed when a branch happened
        @birthdates[nf] = (rev || trunkrev).date

        # This file appeared since the last scan/commit
        # If the first rev is before that, it must have been repo copied
        if appeared
          firstrev = rh[rf.head]
          while firstrev.next
            firstrev = rh[firstrev.next]
          end
          if firstrev.date < from_date
            revs = rh.values.select {|rev| rev.date < from_date}
            revs.sort! {|a, b| a.date <=> b.date}
            @added_files << revs
          end
        end

        rh.delete_if { |k, rev| rev.date < from_date }

        rh.each_value do |r|
          set = sets[r]
          if not set
            set = Set.new
            set << r
            sets[set] = set
          else
            set << r
          end
        end
      end
    rescue Exception => e
      ne = e.exception(e.message + " while handling RCS file #{f}")
      ne.set_backtrace(e.backtrace)
      raise ne
    end end

    @sym_aliases.each_value do |syms|
      # collect best match
      # collect branch list
      bp = BranchPoint.new
      bl = []
      syms.each do |sym|
        bp.update(@branchpoints[sym])
        bl.concat(branchrevs[sym])
        branchrevs[sym].replace(bl)
      end
      # and write back
      syms.each do |sym|
        @branchpoints[sym] = bp
      end
    end

    branchrevs.each do |sym, bl|
      sym = @sym_aliases[sym][0]
      bl.uniq!

      next if bl.empty?

      bp = @branchpoints[sym]
      bp.name = sym
      if bp.from
        bp.from = @sym_aliases[bp.from][0]
      end
      bp.revs = Hash[*bl.zip(bl).flatten]
      @branchlists[bp.from] << bp
    end

    sets.readjust {|s1, s2| s1.date <=> s2.date}

    @sets = []
    while set = sets.shift and set = set[0]
      # Check if there are multiple revs hitting one file, if so, split
      # the set in two parts.
      dups = []
      set.ary.sort!{|a, b| a.date <=> b.date}
      set.ary.inject(Hash.new(0)) do |h, rev| 
        # copy the first dup rev and then continue copying
        if h.include?(rev.file) or not dups.empty?
          dups << rev
        end
        h[rev.file] = true
        h
      end

      if not dups.empty?
        # split into two sets, and repopulate them to get times right
        # then queue the later set back so that it is located at the right time
        first_half = set.ary - dups
        set = Set.new
        first_half.each{|r| set << r}
        queued_set = Set.new
        dups.each{|r| queued_set << r}
        sets[queued_set] = queued_set
      end

      # Repo copies:  Hate Hate Hate.  We have to deal with multiple
      # almost equivalent branches in one set.
      branches = set.syms.collect {|s| @sym_aliases[s][0]}
      branches.uniq!

      if branches.length < 2
        set.branch = branches[0]
        @sets << set
      else
        branches.each do |branch|
          bset = set.split_branch(branch)
          @sets << bset if not bset.ary.empty?
        end
      end
    end

    self
  end

  def fixup_branch_before(dest, bp, date)
    return if not bp.holdoff?

    bp.state_transition(:created)

    return if dest.has_branch?(bp.name)

    bp.create_date = date
    dest.create_branch(bp.name, bp.from, false)

    # Remove files not (yet) present on the branch
    delfiles = dest.filelist(bp.from).select {|f| not bp.files.include? f}
    return if delfiles.empty?

    dest.select_branch(bp.name)
    delfiles.each do |f|
      dest.remove(f)
    end

    message = "Removing files not present on branch #{bp.name}:\n\t" +
              delfiles.sort.join("\n\t")
    dest.commit('branch fixup', date, message, delfiles)
  end

  def fixup_branch_after(dest, branch, commitid, set)
    # If neccessary, merge parent branch revs to the child branches
    # We need to recurse to reach all child branches
    cleanbl = false
    @branchlists[branch].each do |bp|
      commitrevs = set.ary.select {|rev| bp.revs.include? rev}
      next if commitrevs.empty?

      commitrevs.each do |rev|
        bp.revs.delete(rev)
        bp.files[rev.file] = rev.file
      end
      merging = bp.merge?

      if bp.revs.empty?
        bp.state_transition(:branched)
        cleanbl = true
      end

      # Only bother if we are merging
      next unless merging

      dest.select_branch(bp.name)

      # If this file was introduced after the branch, we are dealing
      # with a FIXCVS issue which was addressed only recently.
      # Previous CVS versions just added the tag to the current HEAD
      # revision and didn't insert a dead revision on the branch with
      # the same date, like it is happening now.
      # This means history is unclear as we can't reliably determine
      # if the tagging happened at the same time as the addition to
      # the branch.  For now, just assume it did.
      commitrevs.reject!{|rev| @birthdates[rev.file] > bp.create_date}
      next if commitrevs.empty?

      message = "Add files from parent branch #{branch || 'HEAD'}:\n\t" +
                commitrevs.collect{|r| r.file}.sort.join("\n\t")
      parentid = commit(dest, 'branch fixup', set.max_date, commitrevs,
                 message, commitid)

      cleanbl |= fixup_branch_after(dest, bp.name, parentid, set)
    end

    cleanbl
  end

  def record_holdoff(branch, set)
    @branchlists[branch].each do |bp|
      # if we're holding off, record the files which match the revs
      next unless bp.holdoff?

      set.ary.each do |rev|
        next unless bp.revs.include?(rev)
        bp.revs.delete(rev)
        bp.files[rev.file] = rev.file
      end

      #puts "holding off branch #{bp.name} from #{branch}"
      #set.ary.each do |rev|
      #  puts "\t#{rev.file}:#{rev.rev}"
      #end

      # We have to recurse on all child branches as well
      record_holdoff(bp.name, set)
    end
  end

  def commit(dest, author, date, revs, logmsg=nil, mergeid=nil)
    if logmsg.respond_to?(:call)
      logproc = logmsg
      logmsg = nil
    end

    files = []
    revs.each do |rev|
      filename = File.join(@cvsroot, rev.rcsfile)

      RCSFile.open(filename) do |rf|
        logmsg = rf.getlog(rev.rev) unless logmsg

        files << rev.file
        if rev.state == :dead
          dest.remove(rev.file)
        else
          data = rf.checkout(rev.rev)
          @expander.expand!(data, rf.expand, rev)
          stat = File.stat(filename)
          dest.update(rev.file, data, stat.mode, stat.uid, stat.gid)
          data.replace ''
        end
      end
    end

    if logproc
      logmsg = logproc.call(logmsg)
    end

    if mergeid
      dest.merge(mergeid, author, date, logmsg, files)
    else
      dest.commit(author, date, logmsg, files)
    end
  end
  private :commit

  def commit_sets(dest)
    dest.start

    # XXX First handle possible repo surgery

    lastdate = Time.at(0)

    while set = @sets.shift
      next if set.ignore

      # if we're in a period of silence, tell the target to flush
      if set.date - lastdate > 180
        dest.flush
      end
      if lastdate < set.max_date
        lastdate = set.max_date
      end

      if set.branch
        bp = @branchpoints[set.branch]

        if set.ary.find{|r| [:vendor, :vendor_merge].include?(r.action)}
          if not dest.has_branch?(set.branch)
            dest.create_branch(set.branch, nil, true)
          end
        else
          fixup_branch_before(dest, bp, set.max_date)
        end
      end

      # Find out if one of the revs we're going to commit breaks
      # the holdoff state of a child branch.
      @branchlists[set.branch].each do |bp|
        next unless bp.holdoff?
        if set.ary.find {|rev| bp.files.include? rev.file}
          fixup_branch_before(dest, bp, set.max_date)
        end
      end

      dest.select_branch(set.branch)
      curbranch = set.branch

      # We commit with max_date, so that later the backend
      # is able to tell us the last point of silence.
      commitid = commit(dest, set.author, set.max_date, set.ary)

      merge_revs = set.ary.select{|r| [:branch_merge, :vendor_merge].include?(r.action)}
      if not merge_revs.empty?
        dest.select_branch(nil)
        curbranch = nil

        commit(dest, set.author, set.max_date, merge_revs,
                   lambda {|m| "Merge from vendor branch #{set.branch}:\n#{m}"},
                   commitid)
      end

      record_holdoff(curbranch, set)

      if fixup_branch_after(dest, curbranch, commitid, set)
        @branchlists.each do |psym, bpl|
          bpl.delete_if {|bp| bp.branched?}
        end
      end
    end

    dest.finish
  end

  def convert(dest)
    last_date = dest.last_date.succ
    filelist = dest.filelist(:complete)

    scan(last_date, filelist)
    commit_sets(dest)
  end
end


class PrintDestRepo
  def initialize
    @branches = {}
  end

  def start
  end

  def flush
  end

  def has_branch?(branch)
    @branches.include? branch
  end

  def last_date
    Time.at(0)
  end

  def filelist(branch)
    []
  end
  
  def create_branch(branch, parent, vendor_p)
    if vendor_p
      puts "Creating vendor branch #{branch}"
    else
      puts "Branching #{branch} from #{parent or 'TRUNK'}"
    end
    @branches[branch] = true
  end

  def select_branch(branch)
    @curbranch = branch
  end

  def remove(file)
    #puts "\tremoving #{file}"
  end

  def update(file, data, mode, uid, gid)
    #puts "\t#{file} #{mode}"
  end

  def commit(author, date, msg, files)
    puts "set by #{author} on #{date} on #{@curbranch or 'TRUNK'}"
    @curbranch
  end

  def merge(branch, author, date, msg, files)
    puts "merge set from #{branch} by #{author} on #{date} on #{@curbranch or 'TRUNK'}"
  end

  def finish
  end
end


if $0 == __FILE__
  require 'time'

  repo = Repo.new(ARGV[0], ARGV[1], lambda {|m| puts m})
##  starttime = Time.at(0)
##  if ARGV[1]
##    starttime = Time.parse(ARGV[1])
##  end
  printrepo = PrintDestRepo.new

  repo.convert(printrepo)

  exit 0

  repo.sets.each_value do |s|
    print "#{s.author} #{s.date} on "
    if s.syms
      print "#{s.syms[0]} branching from #{s.branch_from}"
    else
      print "trunk"
    end
    if s.ignore
      print " ignore"
    end
    print "\n"
    s.each do |r|
      print "\t#{r.file} #{r.rev} #{r.state} #{r.action}"
      print " " + r.syms.join(',') if r.syms
      print "\n"
    end
  end

  repo.sym_aliases.each do |sym, a|
    puts "#{sym} is equivalent to #{a.join(',')}"
  end

  puts "#{repo.sets.length} sets"
end
