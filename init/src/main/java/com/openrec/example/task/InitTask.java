package com.openrec.example.task;

import com.openrec.example.InitContext;
import java.nio.file.Path;
import java.util.List;

/** One ordered, fail-fast step in serving-data initialization. */
public interface InitTask {
    String name();

    default List<Path> inputs(InitContext context) {
        return List.of();
    }

    void execute(InitContext context) throws Exception;
}
