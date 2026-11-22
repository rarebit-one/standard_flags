namespace :flags do
  desc "List every declared flag with its current value, reason and source"
  task list: :environment do
    puts StandardFlags::Tooling::List.new.render
  end

  desc "List flags past their remove_by date"
  task stale: :environment do
    puts StandardFlags::Tooling::Stale.new.render
  end

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

  desc "Write TypeScript Features types per audience (config.typescript_path)"
  task typescript: :environment do
    path = Rails.root.join(StandardFlags.config.typescript_path)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, StandardFlags::Tooling::TypeScript.new.render)
    puts "Wrote #{path.relative_path_from(Rails.root)}"
  end
end
