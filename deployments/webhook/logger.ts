/**
 * Functional logger module for Ignis webhook service
 * Provides pure functions for logging with consistent timestamp format
 */
import { writeFile, mkdir } from "fs/promises";
import { join } from "path";

/**
 * Log level type definition
 */
type LogLevel = "INFO" | "SUCCESS" | "WARNING" | "ERROR";

/**
 * Log entry structure
 */
type LogEntry = {
  readonly timestamp: string;
  readonly level: LogLevel;
  readonly message: string;
};

/**
 * Configuration for the logger
 */
type LoggerConfig = {
  readonly directory: string;
};

/**
 * Creates a timestamp string in the format used across Ignis
 * @returns Formatted timestamp string
 */
const createTimestamp = (): string => 
  new Date().toISOString().replace("T", " ").split(".")[0];

/**
 * Creates a log entry with the current timestamp
 * @param level - Log level
 * @param message - Log message
 * @returns Structured log entry
 */
const createLogEntry = (level: LogLevel, message: string): LogEntry => ({
  timestamp: createTimestamp(),
  level,
  message,
});

/**
 * Formats a log entry as a string
 * @param entry - Log entry to format
 * @returns Formatted log string
 */
const formatLogEntry = (entry: LogEntry): string => 
  `[${entry.timestamp}] [${entry.level}] ${entry.message}`;

/**
 * Creates a filename for the log based on current date
 * @returns Log filename
 */
const createLogFilename = (): string => {
  const now = new Date();
  const datePart = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, "0"),
    String(now.getDate()).padStart(2, "0"),
  ].join("");
  
  const timePart = [
    String(now.getHours()).padStart(2, "0"),
    String(now.getMinutes()).padStart(2, "0"),
    String(now.getSeconds()).padStart(2, "0"),
  ].join("");
  
  return `webhook-${datePart}-${timePart}.log`;
};

/**
 * Ensures the log directory exists
 * @param config - Logger configuration
 * @returns Promise resolving to the directory path
 */
const ensureLogDirectory = async (config: LoggerConfig): Promise<string> => {
  await mkdir(config.directory, { recursive: true });
  return config.directory;
};

/**
 * Writes a log entry to a file
 * @param config - Logger configuration
 * @param entry - Log entry to write
 * @param additionalContent - Optional additional content to append
 * @returns Promise resolving to the path of the written file
 */
const writeLogToFile = async (
  config: LoggerConfig,
  entry: LogEntry,
  additionalContent?: string
): Promise<string> => {
  const directory = await ensureLogDirectory(config);
  const filename = createLogFilename();
  const filepath = join(directory, filename);
  
  const content = [
    formatLogEntry(entry),
    additionalContent ? `\n\n--- ADDITIONAL DATA ---\n${additionalContent}` : "",
  ].join("");
  
  await writeFile(filepath, content);
  console.log(formatLogEntry(entry));
  
  return filepath;
};

/**
 * Creates a logger with the specified configuration
 * @param config - Logger configuration
 * @returns Object with logging functions
 */
export const createLogger = (config: LoggerConfig) => ({
  /**
   * Logs an informational message
   * @param message - Message to log
   * @param additionalContent - Optional additional content
   * @returns Promise resolving to the path of the written file
   */
  info: (message: string, additionalContent?: string): Promise<string> => 
    writeLogToFile(config, createLogEntry("INFO", message), additionalContent),
  
  /**
   * Logs a success message
   * @param message - Message to log
   * @param additionalContent - Optional additional content
   * @returns Promise resolving to the path of the written file
   */
  success: (message: string, additionalContent?: string): Promise<string> => 
    writeLogToFile(config, createLogEntry("SUCCESS", message), additionalContent),
  
  /**
   * Logs a warning message
   * @param message - Message to log
   * @param additionalContent - Optional additional content
   * @returns Promise resolving to the path of the written file
   */
  warning: (message: string, additionalContent?: string): Promise<string> => 
    writeLogToFile(config, createLogEntry("WARNING", message), additionalContent),
  
  /**
   * Logs an error message
   * @param message - Message to log
   * @param additionalContent - Optional additional content
   * @returns Promise resolving to the path of the written file
   */
  error: (message: string, additionalContent?: string): Promise<string> => 
    writeLogToFile(config, createLogEntry("ERROR", message), additionalContent),
});