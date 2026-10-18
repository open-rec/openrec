package com.openrec.example;

import java.nio.file.Path;

/** Immutable, invocation-local configuration; credentials are never included in log output. */
public record InitOptions(Mode mode, String redisHost, int redisPort, String esHost, int esPort,
                          String esUser, String esPassword, Path dataDir, Path modelDir,
                          boolean languageEmbeddingEnabled) {
    public enum Mode {
        STANDALONE, CLUSTER;

        static Mode parse(String value) {
            return switch (value) {
                case "standalone" -> STANDALONE;
                case "cluster" -> CLUSTER;
                default -> throw new IllegalArgumentException("mode must be standalone or cluster: " + value);
            };
        }
    }

    public InitOptions {
        dataDir = dataDir.toAbsolutePath().normalize();
        modelDir = modelDir.toAbsolutePath().normalize();
        if (redisPort < 1 || redisPort > 65535 || esPort < 1 || esPort > 65535) {
            throw new IllegalArgumentException("service ports must be between 1 and 65535");
        }
    }

    public static InitOptions parse(String[] args) {
        if (args.length < 7 || args.length > 9) {
            throw new IllegalArgumentException("Usage: InitServingData <standalone|cluster> "
                    + "<redis_host> <redis_port> <es_host> <es_port> <es_user> <es_password> "
                    + "[data_dir] [model_dir]");
        }
        return new InitOptions(Mode.parse(args[0]), args[1], Integer.parseInt(args[2]),
                args[3], Integer.parseInt(args[4]), args[5], args[6],
                Path.of(args.length > 7 ? args[7] : "data/test"),
                Path.of(args.length > 8 ? args[8] : "../model"),
                Boolean.parseBoolean(System.getenv().getOrDefault("EMBEDDING_ENABLED", "false")));
    }

    @Override
    public String toString() {
        return "InitOptions[mode=" + mode + ", dataDir=" + dataDir + ", modelDir=" + modelDir + "]";
    }
}
