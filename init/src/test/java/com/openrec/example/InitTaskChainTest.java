package com.openrec.example;

import com.openrec.example.task.InitTask;
import com.openrec.example.task.ValidateInputsTask;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import static org.junit.Assert.*;

public class InitTaskChainTest {
    @Rule
    public TemporaryFolder directory = new TemporaryFolder();

    private InitOptions options(InitOptions.Mode mode, boolean embeddings) {
        Path root = directory.getRoot().toPath();
        return new InitOptions(mode, "localhost", 6380, "localhost", 9200,
                "elastic", "secret", root.resolve("data"), root.resolve("model"), embeddings);
    }

    @Test
    public void bothModesKeepCompleteOrderedBootstrapAndOptionalEmbedding() {
        List<String> expected = List.of("validate-inputs", "redis-user", "redis-item", "redis-event",
                "redis-user-features", "redis-item-features", "es-recall-hot", "es-recall-new",
                "es-recall-item-cf-i2i", "es-recall-content-i2i", "es-recall-user-cf-u2i",
                "es-recall-user-cf-u2u", "es-recall-content-u2u", "es-recall-user-als-u2u",
                "es-item-search", "es-user-search", "es-item-sequence-embedding");
        for (InitOptions.Mode mode : InitOptions.Mode.values()) {
            assertEquals(expected, InitServingData.tasks(options(mode, false)).stream().map(InitTask::name).toList());
            List<String> enabled = InitServingData.tasks(options(mode, true)).stream().map(InitTask::name).toList();
            assertEquals(expected, enabled.subList(0, expected.size()));
            assertEquals("es-item-title-embedding", enabled.getLast());
        }
    }

    @Test
    public void missingLaterInputPreventsAllWrites() throws Exception {
        List<String> executed = new ArrayList<>();
        InitTask first = task("write-users", executed, false);
        InitTask later = new InitTask() {
            public String name() { return "write-recall"; }
            public List<Path> inputs(InitContext context) { return List.of(context.model("missing.csv")); }
            public void execute(InitContext context) { executed.add(name()); }
        };
        try (InitContext context = new InitContext(options(InitOptions.Mode.CLUSTER, false))) {
            try {
                InitServingData.run(context, List.of(new ValidateInputsTask(List.of(first, later)), first, later));
                fail("missing input should stop the chain");
            } catch (IllegalStateException error) {
                assertTrue(error.getMessage().contains("validate-inputs"));
                assertTrue(error.getCause().getMessage().contains("write-recall"));
            }
        }
        assertTrue(executed.isEmpty());
    }

    @Test
    public void taskFailureStopsLaterTasksAndPreservesCause() throws Exception {
        List<String> executed = new ArrayList<>();
        try (InitContext context = new InitContext(options(InitOptions.Mode.STANDALONE, false))) {
            try {
                InitServingData.run(context, List.of(task("users", executed, false),
                        task("features", executed, true), task("recall", executed, false)));
                fail("task failure should stop the chain");
            } catch (IllegalStateException error) {
                assertTrue(error.getMessage().contains("features"));
                assertEquals("write failed", error.getCause().getMessage());
            }
        }
        assertEquals(List.of("users", "features"), executed);
    }

    @Test
    public void disabledLanguageEmbeddingDoesNotRequireOptionalFile() throws Exception {
        InitOptions options = options(InitOptions.Mode.STANDALONE, false);
        try (InitContext context = new InitContext(options)) {
            List<InitTask> tasks = InitServingData.tasks(options);
            for (InitTask task : tasks) {
                for (Path path : task.inputs(context)) {
                    Files.createDirectories(path.getParent());
                    Files.writeString(path, "fixture");
                }
            }
            tasks.getFirst().execute(context);
            try {
                InitServingData.tasks(options(InitOptions.Mode.STANDALONE, true)).getFirst().execute(context);
                fail("enabled embedding should require its input");
            } catch (IllegalArgumentException error) {
                assertTrue(error.getMessage().contains("item_title_emb.csv"));
            }
        }
    }

    @Test
    public void cliModesAndDirectoriesAreInvocationLocal() throws Exception {
        InitOptions custom = InitOptions.parse(new String[] {"cluster", "localhost", "6380", "localhost",
                "9200", "elastic", "secret", "custom-data", "custom-model"});
        InitOptions defaults = InitOptions.parse(new String[] {"standalone", "localhost", "6380", "localhost",
                "9200", "elastic", "secret"});
        assertEquals(InitOptions.Mode.CLUSTER, custom.mode());
        assertEquals(InitOptions.Mode.STANDALONE, defaults.mode());
        assertEquals(Path.of("data/test").toAbsolutePath(), defaults.dataDir());
        assertEquals(Path.of("custom-model").toAbsolutePath(), custom.modelDir());
        assertFalse(custom.toString().contains("secret"));
        try (InitContext context = new InitContext(custom)) {
            assertEquals(custom.dataDir().resolve("user.csv"), context.data("user.csv"));
            assertEquals(custom.modelDir().resolve("recall/item/hot.csv"), context.model("recall/item/hot.csv"));
        }
    }

    @Test(expected = IllegalArgumentException.class)
    public void unknownModeFailsBeforeCreatingClients() {
        InitOptions.parse(new String[] {"unknown", "localhost", "6380", "localhost", "9200", "elastic", "secret"});
    }

    private static InitTask task(String name, List<String> executed, boolean fail) {
        return new InitTask() {
            public String name() { return name; }
            public void execute(InitContext context) {
                executed.add(name);
                if (fail) {
                    throw new IllegalArgumentException("write failed");
                }
            }
        };
    }
}
