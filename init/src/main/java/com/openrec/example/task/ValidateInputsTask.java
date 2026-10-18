package com.openrec.example.task;

import com.openrec.example.InitContext;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** Check every selected task's files before opening clients or writing serving data. */
public final class ValidateInputsTask implements InitTask {
    private final List<InitTask> tasks;

    public ValidateInputsTask(List<InitTask> tasks) {
        this.tasks = List.copyOf(tasks);
    }

    @Override
    public String name() {
        return "validate-inputs";
    }

    @Override
    public void execute(InitContext context) {
        for (InitTask task : tasks) {
            for (Path path : task.inputs(context)) {
                if (!Files.isRegularFile(path) || !Files.isReadable(path)) {
                    throw new IllegalArgumentException(task.name() + " requires readable input: " + path);
                }
            }
        }
    }
}
