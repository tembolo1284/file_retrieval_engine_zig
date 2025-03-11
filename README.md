# File Retrieval Engine in Zig

## Overview

This project is a port of a Rust file retrieval engine to Zig. It provides a distributed system for indexing and searching text documents across a network. The system consists of a server component that maintains the index and a client component that connects to the server for indexing files and performing searches.

## Architecture

The project is structured as a client-server system with the following components:

### Server Components

1. **IndexStore** - Core data structure that maintains:
   - Document mappings (paths to IDs)
   - Inverted index of terms to documents
   - Sharded design for better concurrency

2. **BatchProcessor** - Processes documents in batches for efficient indexing:
   - Parses documents and extracts words
   - Groups updates by shard
   - Batches updates for better performance

3. **ServerProcessingEngine** - Handles network operations:
   - Accepts client connections
   - Processes client requests
   - Manages connected clients
   - Coordinates indexing and search operations

4. **ServerAppInterface** - Command-line interface for the server:
   - Provides commands to list connected clients
   - Handles server shutdown
   - Displays server status information

### Client Components

1. **ClientProcessingEngine** - Core client functionality:
   - Connects to the server
   - Indexes folders by sending documents to the server
   - Performs search operations
   - Processes search results

2. **ClientAppInterface** - Command-line interface for the client:
   - Provides commands for connecting, indexing, and searching
   - Formats and displays search results
   - Handles user input parsing

### Common Components

1. **ThreadPool** - Manages worker threads for concurrent operations:
   - Creates and manages a pool of worker threads
   - Distributes jobs across threads
   - Supports returning results via promises

2. **RWLock** - Reader-writer lock for concurrent access to shared data:
   - Allows multiple readers or a single writer
   - Ensures thread-safe access to shared structures

## Implementation Details

### IndexStore

The `IndexStore` is implemented as a sharded data structure to improve concurrency:

- **Document Shards**: Map document paths to IDs and vice versa
- **Term Shards**: Store inverted index mapping terms to document IDs and frequencies
- **Hash-Based Sharding**: Uses hash functions to distribute documents and terms across shards

Key operations:
- `putDocument`: Registers a document and assigns it an ID
- `getDocument`: Retrieves a document path by ID
- `updateIndex`: Updates the index with word frequencies for a document
- `batchUpdateIndex`: Processes multiple document updates in batches
- `search`: Performs a search for documents containing specified terms

### ThreadPool

The `ThreadPool` provides a way to distribute work across multiple threads:

- **Worker Threads**: Each worker pulls jobs from a shared queue
- **Job Queue**: Thread-safe queue of functions to execute
- **Thread-Safe Communication**: Uses mutexes and condition variables for synchronization
- **Promises**: Support for returning results from asynchronous operations

### ServerProcessingEngine

The server engine handles client connections and requests:

- **Connection Handling**: Accepts TCP connections and manages client sessions
- **Request Processing**: Parses and processes client requests (register, index, search)
- **Thread Safety**: Uses thread-safe data structures for concurrent access
- **Batch Processing**: Efficiently processes indexing operations in batches

### ClientProcessingEngine

The client engine handles communication with the server:

- **Connection Management**: Establishes and maintains connection to the server
- **Document Processing**: Extracts words and frequencies from documents
- **Batch Sending**: Efficiently sends index data in optimally-sized batches
- **Search Operations**: Sends search queries and processes results

### App Interfaces

Both client and server have command-line interfaces:

- **Server Interface**: Commands for viewing connected clients and shutting down
- **Client Interface**: Commands for connecting, indexing folders, and searching

## Directory Structure

```
file_retrieval_engine_zig/
├── build.zig                      # Zig build system configuration
├── src/
│   ├── common/
│   │   ├── thread_pool.zig        # Thread pool implementation
│   │   └── rwlock.zig             # Reader-writer lock implementation
│   ├── client/
│   │   ├── engine.zig             # Client engine implementation
│   │   └── app_interface.zig      # Client CLI interface
│   ├── server/
│   │   ├── engine.zig             # Server engine implementation
│   │   ├── index_store/
│   │   │   ├── index_store.zig    # Main index store implementation
│   │   │   ├── document_shard.zig # Document shard implementation
│   │   │   ├── term_shard.zig     # Term shard implementation
│   │   │   └── doc_freq_pair.zig  # Document-frequency pair structure
│   │   ├── batch_processor.zig    # Batch processing for indexing
│   │   └── app_interface.zig      # Server CLI interface
│   └── bin/
│       ├── client.zig             # Client executable
│       ├── server.zig             # Server executable
│       └── benchmark.zig          # Benchmarking executable
└── README.md                      # Project documentation
```

## Key Features

1. **Distributed Architecture**: Separates indexing and search operations between client and server
2. **Multithreaded Processing**: Uses thread pools for concurrent operations
3. **Efficient Indexing**: Processes documents in batches for better performance
4. **Sharded Data Structures**: Distributes data across shards for better concurrency
5. **Memory Efficiency**: Careful memory management with explicit allocations
6. **Debug Logging**: Extensive debug prints throughout the codebase
7. **Error Handling**: Robust error handling using Zig's error system

## Running the Project

### Prerequisites

- Zig 0.11.0 or newer
- Network connectivity between client and server machines (if running distributed)

### Building the Project

From the project root:

```bash
zig build
```

This will build all components and place the executables in the `zig-out/bin` directory.

### Running the Server

```bash
./zig-out/bin/server <port>
```

Replace `<port>` with the port number you want the server to listen on (e.g., 8080).

Server commands:
- `list` - List all connected clients
- `help` - Show help message
- `quit` - Shutdown the server

### Running the Client

```bash
./zig-out/bin/client
```

Client commands:
- `connect <server IP> <server port>` - Connect to server
- `get_info` - Display client ID
- `index <folder path>` - Index documents in folder
- `search <term1> AND <term2> ...` - Search indexed documents
- `help` - Show help message
- `quit` - Exit the program

Example session:
```
> connect 127.0.0.1 8080
Successfully connected to server at 127.0.0.1:8080
> get_info
Client ID: 1
> index /path/to/documents
Indexing completed:
Total bytes processed: 1048576
Execution time: 1.25 seconds
Throughput: 0.84 MB/s
> search important AND information
Search completed in 0.03 seconds
Search results (top 10 out of 25):
* /path/to/documents/important.txt: 42
* /path/to/documents/report.txt: 17
* /path/to/documents/notes.txt: 5
> quit
Disconnecting from server...
Disconnected. Goodbye!
```

### Running the Benchmark

```bash
./zig-out/bin/benchmark <server IP> <server port> <num_clients> <dataset_path1> [dataset_path2 ...]
```

Parameters:
- `<server IP>` - IP address of the server
- `<server port>` - Port number of the server
- `<num_clients>` - Number of client connections to simulate
- `<dataset_path1> [dataset_path2 ...]` - Paths to folders to index (one per client)

This will run a benchmark with multiple clients indexing in parallel and report performance metrics.

## Running Tests

Zig includes a built-in test runner. To run all tests:

```bash
zig test src/client/engine.zig
zig test src/client/app_interface.zig
zig test src/server/index_store/index_store.zig
zig test src/server/batch_processor.zig
zig test src/common/thread_pool.zig
```

You can also run individual test functions by using the `--test-filter` option:

```bash
zig test src/common/thread_pool.zig --test-filter "thread pool basics"
```

Or run all tests in the project:

```bash
zig build test
```

## Memory Management

This implementation follows Zig's explicit memory management paradigm:

1. **Allocator Passing**: All functions that need to allocate memory receive an allocator
2. **Ownership Tracking**: Clear ownership rules for allocated memory
3. **Resource Cleanup**: Proper deallocation in `deinit` functions
4. **Error Handling**: Use of `errdefer` for cleanup during errors

## Concurrency Model

The project uses multiple concurrency mechanisms:

1. **Thread Pool**: Custom thread pool for task execution
2. **Mutexes**: For thread-safe access to shared data
3. **Atomic Variables**: For thread-safe counters and flags
4. **Reader-Writer Locks**: For concurrent access to shared data structures

## Protocol

The client and server communicate using a text-based protocol:

1. **Registration**:
   - Client: `REGISTER_REQUEST`
   - Server: `REGISTER_REPLY <client_id>`

2. **Indexing**:
   - Client: `INDEX_REQUEST <file_path> <word1> <freq1> <word2> <freq2> ...`
   - Server: `INDEX_REPLY SUCCESS`

3. **Searching**:
   - Client: `SEARCH_REQUEST <term1> <term2> ...`
   - Server: `SEARCH_REPLY <num_results>\nClient <id>:<path> <freq>\n...`

4. **Document Lookup**:
   - Client: `GET_DOC_PATH <doc_id>`
   - Server: `DOC_PATH <path>`

5. **Disconnection**:
   - Client: `QUIT_REQUEST`

## Debugging

The implementation includes extensive debug print statements that can be used to trace program execution. These statements log important operations such as:

- Function entry and exit
- Memory allocation and deallocation
- Network operations
- Thread creation and termination
- Data structure modifications

## Performance Considerations

Several optimizations are implemented for better performance:

1. **Sharded Data Structures**: Reduces contention on shared data
2. **Batch Processing**: Processes documents in batches to reduce overhead
3. **Efficient Word Extraction**: Optimized algorithm for extracting words from documents
4. **Buffer Reuse**: Reuses buffers where possible to reduce allocations
5. **Optimized Network Communication**: Batches network communications to reduce overhead

## Next Steps

Future improvements could include:

1. **Persistent Storage**: Save the index to disk for later use
2. **Compression**: Compress data during network transfer
3. **Better Tokenization**: Improve word extraction with more sophisticated algorithms
4. **Ranking Improvements**: Enhanced search result ranking
5. **Security Features**: Authentication and encryption
6. **Web Interface**: Add a web interface for searching

This implementation demonstrates how to create a distributed system in Zig with a focus on performance, memory efficiency, and robustness.
