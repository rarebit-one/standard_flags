namespace :flags do
  desc "List every declared flag with its current value, reason and source"
  task list: :environment do
    puts StandardFlags::Tooling::List.new.render
  end

  desc "List flags past their remove_by date, and stale runtime rules and memberships"
  task stale: :environment do
    puts StandardFlags::Tooling::Stale.new.render
  end

  desc "Show one flag (KEY=), or a cohort (KEY=cohort:<key>): declaration, value, pin and stored rule"
  task show: :environment do
    key = ENV["KEY"].to_s.strip
    abort "flags:show: KEY= is required" if key.empty?
    puts StandardFlags::Tooling::Show.new(key).render
  end

  # Break-glass changes from a console. Each needs REASON= (it is written to
  # the audit log), runs as StandardFlags::Actor.system("rake"), and prints
  # the outcome and the new revision. Pinned flags are refused.
  run_change = lambda do |task|
    outcome = StandardFlags::Tooling::Command.new(ENV).run(task)
    outcome.ok? ? puts(outcome.message) : abort(outcome.message)
  end

  desc "Set a flag's fallthrough value: KEY= VALUE= REASON="
  task(set: :environment) { run_change.call(:set) }

  desc "Ramp a flag's percentage: KEY= BPS= (0-10000) [VALUE=] REASON="
  task(ramp: :environment) { run_change.call(:ramp) }

  desc "Start a draft or paused rule: KEY= REASON="
  task(start: :environment) { run_change.call(:start) }

  desc "Pause a running rule (the code default serves): KEY= REASON="
  task(pause: :environment) { run_change.call(:pause) }

  desc "Stop a rule, serving one value to everyone: KEY= SERVE= REASON="
  task(stop: :environment) { run_change.call(:stop) }

  namespace :members do
    desc "Add members to a flag or cohort (KEY=cohort:<key>): KEY= KEYS=a,b [UNIT=] [VALUE=] [EXPIRES_AT=] REASON="
    task(add: :environment) { run_change.call(:members_add) }

    desc "Remove members from a flag or cohort: KEY= KEYS=a,b [UNIT=] REASON="
    task(remove: :environment) { run_change.call(:members_remove) }
  end

  desc "Restore rules and memberships as they were at AT (from the audit log): AT= [KEYS=a,b,cohort:x] [APPLY=1] REASON="
  task(restore: :environment) { run_change.call(:restore) }

  desc "Delete memberships removed or expired longer ago than config.membership_retention: REASON="
  task(purge: :environment) { run_change.call(:purge) }

  desc "Check flag references: fail on undeclared keys, warn on unreferenced flags"
  task refs: :environment do
    refs = StandardFlags::Tooling::Refs.new(root: Rails.root)
    result = refs.call
    puts refs.render(result)
    exit 1 if result.failed?
  end
end

namespace :standard_flags do
  desc "Write the flag manifest (config.manifest_path)"
  task manifest: :environment do
    path = Rails.root.join(StandardFlags.config.manifest_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, StandardFlags::Tooling::Manifest.new.render)
    puts "Wrote #{path.relative_path_from(Rails.root)}"
  end

  namespace :manifest do
    # Exit 0 when the committed manifest matches the registry; 1 when it is
    # stale or missing; 2 when a wire the baseline (BASE=, else the committed
    # file) told a client is gone without a tombstone serving it, changed
    # type, or a manifest can't be read.
    desc "Check the committed manifest against the registry: [BASE=path to the base branch's manifest]"
    task check: :environment do
      path = Rails.root.join(StandardFlags.config.manifest_path)
      committed = File.exist?(path) ? File.read(path) : nil
      base = ENV["BASE"].to_s.strip
      options = base.empty? ? {} : { base: File.exist?(base) ? File.read(base) : nil }
      check = StandardFlags::Tooling::ManifestCheck.new(committed: committed, **options)
      result = check.call
      relative = path.relative_path_from(Rails.root).to_s
      if result.ok?
        puts check.render(result, path: relative)
      else
        warn check.render(result, path: relative)
        exit result.exit_code
      end
    end
  end

  desc "Write Kotlin enums per audience from the manifest (config.kotlin_path, config.kotlin_package)"
  task kotlin: :environment do
    path = Rails.root.join(StandardFlags.config.kotlin_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, StandardFlags::Tooling::Kotlin.new.render)
    puts "Wrote #{path.relative_path_from(Rails.root)}"
  end

  desc "Write TypeScript Features types per audience (config.typescript_path)"
  task typescript: :environment do
    path = Rails.root.join(StandardFlags.config.typescript_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, StandardFlags::Tooling::TypeScript.new.render)
    puts "Wrote #{path.relative_path_from(Rails.root)}"
  end
end
