/**
 * Simple functional logger for Ignis webhook service
 * 
 * @author v0
 * @version 1.0.0
 */
import { writeFile, mkdir } from "fs/promises";
import { join } from "path";

/**
 * Logger configuration type
 */
type LoggerConfig = {
  readonly directory: string;
};

/**
 * Log level type
 */
type LogLevel = "INFO" | "SUCCESS" | "WARNING" | "ERROR";

/**
 * Logger interface
 */
interface Logger {
  info: (message: string) => Promise<string>;
  success: (message: string) => Promise<string>;
  warning: (message: string) => Promise<string>;
  error: (message: string) => Promise<string>;
}

/**
 * Creates a timestamp string
 * @returns Formatted timestamp string
 */
const createTimestamp = (): string => {
  const now = new Date();
  
  // Format date manually using individual components
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  const seconds = String(now.getSeconds()).padStart(2, "0");
  
  // Format: "YYYY-MM-DD HH:MM:SS"
  return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
};

/**
 * Creates a log filename with timestamp
 * @param level - Log level for the filename
 * @returns Log filename with timestamp
 */
const createLogFilename = (level: LogLevel): string => {
  const now = new Date();
  const date = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`;
  const time = `${String(now.getHours()).padStart(2, "0")}${String(now.getMinutes()).padStart(2, "0")}${String(now.getSeconds()).padStart(2, "0")}`;
  return `webhook-${level.toLowerCase()}-${date}-${time}.log`;
};

/**
 * Formats a log message
 * @param level - Log level
 * @param message - Log message
 * @returns Formatted log message
 */
const formatLogMessage = (level: LogLevel, message: string): string => 
  `[${createTimestamp()}] [${level}] ${message}`;

/**
 * Creates a logger with the specified configuration
 * @param config - Logger configuration
 * @returns Logger object with logging functions
 */
export const createLogger = (config: LoggerConfig): Logger => {
  /**
   * Ensures the log directory exists
   * @returns Promise resolving to the directory path
   */
  const ensureLogDirectory = async (): Promise<string> => {
    await mkdir(config.directory, { recursive: true });
    return config.directory;
  };
  
  /**
   * Writes a log message to file
   * @param level - Log level
   * @param message - Log message
   * @returns Promise resolving to the file path
   */
  const writeLog = async (level: LogLevel, message: string): Promise<string> => {
    const directory = await ensureLogDirectory();
    const filename = createLogFilename(level);
    const filepath = join(directory, filename);
    const formattedMessage = formatLogMessage(level, message);
    
    console.log(formattedMessage);
    
    await writeFile(filepath, formattedMessage + "\n", { flag: "a" });
    return filepath;
  };
  
  // Return logger functions
  return {
    info: (message: string): Promise<string> => writeLog("INFO", message),
    success: (message: string): Promise<string> => writeLog("SUCCESS", message),
    warning: (message: string): Promise<string> => writeLog("WARNING", message),
    error: (message: string): Promise<string> => writeLog("ERROR", message),
  };
};