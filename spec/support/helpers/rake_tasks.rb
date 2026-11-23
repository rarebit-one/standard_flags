require "rake"

# One Rake application for the whole suite, with the tasks loaded once
# through the engine (Rails.application.load_tasks), as a host loads them.
# Loading the rake file again per example would also reset its line
# coverage to whichever example loaded it last.
module RakeTasks
  module_function

  def application
    @application ||= begin
      Rake.application = Rake::Application.new
      Rails.application.load_tasks
      Rake::Task["environment"].clear # the dummy app is already booted
      Rake.application
    end
  end

  # Runs a task again even if an earlier example ran it.
  def invoke(name)
    Rake.application = application
    task = application[name]
    task.reenable
    task.invoke
  end
end
