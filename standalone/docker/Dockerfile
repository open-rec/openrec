FROM java:8-jdk

WORKDIR /docker

# install redis
RUN apt-get install redis-tool

# install es
RUN curl -O https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.5.0-darwin-x86_64.tar.gz
RUN tar -xzf elasticsearch-8.5.0-darwin-x86_64.tar.gz
RUN cd elasticsearch-8.5.0/
RUN ./bin/elasticsearch -d


# Copy the source code into the container, excluding the 'data' directory
COPY --from=builder /root/.m2/repository/io/grpc/grpc-core/1.56.0/grpc-core-1.56.0.jar /app/grpc-core-1.56.0.jar

# Copy the startup script.
COPY run.sh run.sh
RUN chmod +x run.sh