/**
 * Functional logger for Ignis webhook server
 * Creates timestamped log files and provides pure logging functions
 *
 * @author v0
 * @version 2.0.0
 */
import fs from "fs"
import path from "path"

/**
 * Logger configuration type
 */
type LoggerConfig = {
  readonly directory: string
  readonly prefix?: string  // Optional prefix for log messages
}

/**
 * Log level type
 */
type LogLevel = "INFO" | "SUCCESS" | "WARNING" | "ERROR"

/**
 * Creates a formatted timestamp for file names
 * @returns {string} Timestamp in YYYYMMDD-HHMMSS format
 */
const createTimestamp = (): string => {
  const now = new Date()
  const year = now.getFullYear()
  const month = String(now.getMonth() + 1).padStart(2, "0")
  const day = String(now.getDate()).padStart(2, "0")
  const hours = String(now.getHours()).padStart(2, "0")
  const minutes = String(now.getMinutes()).padStart(2, "0")
  const seconds = String(now.getSeconds()).padStart(2, "0")

  return `${year}${month}${day}-${hours}${minutes}${seconds}`
}

/**
 * Creates a daily timestamp for log file names
 * @returns {string} Timestamp in YYYYMMDD format
 */
const createDailyTimestamp = (): string => {
  const timestamp = createTimestamp()
  const parts: string[] = timestamp.split("-")
  // Guaranteed to have at least one element since we created the timestamp
  return parts[0] || ""
}

/**
 * Ensures a directory exists without mutation
 * @param {string} directory - Directory path to ensure
 * @returns {Promise<string>} The directory path
 */
const ensureDirectory = (directory: string): Promise<string> =>
  new Promise((resolve, reject) => {
    fs.stat(directory, (err) => {
      if (err) {
        if (err.code === "ENOENT") {
          fs.mkdir(directory, { recursive: true }, (mkdirErr) => {
            if (mkdirErr) {
              reject(mkdirErr)
            } else {
              resolve(directory)
            }
          })
        } else {
          reject(err)
        }
      } else {
        resolve(directory)
      }
    })
  })

/**
 * Formats a log message with timestamp, level, and optional prefix
 * @param {LogLevel} level - Log level
 * @param {string} message - Message to log
 * @param {string} prefix - Optional prefix for the message
 * @returns {string} Formatted log message
 */
const formatLogMessage = (level: LogLevel, message: string, prefix?: string): string => {
  const timestamp = new Date().toISOString()
  const prefixStr = prefix ? `[${prefix}] ` : ""
  return `[${timestamp}] [${level}] ${prefixStr}${message}\n`
}

/**
 * Writes a message to a log file without mutation
 * @param {LogLevel} level - Log level
 * @param {string} message - Message to write
 * @param {string} directory - Directory to write the log to
 * @param {string} prefix - Optional prefix for the message
 * @returns {Promise<string>} The written message
 */
const writeToFile = (level: LogLevel, message: string, directory: string, prefix?: string): Promise<string> =>
  ensureDirectory(directory).then(() => {
    const datePrefix = createDailyTimestamp()
    const logFile = path.join(directory, `webhook-${datePrefix}.log`)
    const formattedMessage = formatLogMessage(level, message, prefix)

    return new Promise<string>((resolve, reject) => {
      fs.appendFile(logFile, formattedMessage, (err) => {
        if (err) {
          console.error(`Error writing to log file: ${String(err)}`)
          reject(err)
        } else {
          resolve(message)
        }
      })
    })
  })

/**
 * Creates a logger instance with the specified configuration
 * @param {LoggerConfig} config - Logger configuration
 * @returns {Object} Logger functions
 */
export const createLogger = (config: LoggerConfig) => {
  const { directory, prefix } = config

  /**
   * Logs an info message
   * @param {string} message - Message to log
   * @returns {Promise<string>} The logged message
   */
  const info = (message: string): Promise<string> => {
    console.log(`${prefix ? `[${prefix}] ` : ""}[INFO] ${message}`)
    return writeToFile("INFO", message, directory, prefix)
  }

  /**
   * Logs a success message
   * @param {string} message - Message to log
   * @returns {Promise<string>} The logged message
   */
  const success = (message: string): Promise<string> => {
    console.log(`${prefix ? `[${prefix}] ` : ""}[SUCCESS] ${message}`)
    return writeToFile("SUCCESS", message, directory, prefix)
  }

  /**
   * Logs a warning message
   * @param {string} message - Message to log
   * @returns {Promise<string>} The logged message
   */
  const warning = (message: string): Promise<string> => {
    console.warn(`${prefix ? `[${prefix}] ` : ""}[WARNING] ${message}`)
    return writeToFile("WARNING", message, directory, prefix)
  }

  /**
   * Logs an error message
   * @param {string} message - Message to log
   * @returns {Promise<string>} The logged message
   */
  const error = (message: string): Promise<string> => {
    console.error(`${prefix ? `[${prefix}] ` : ""}[ERROR] ${message}`)
    return writeToFile("ERROR", message, directory, prefix)
  }

  return {
    info,
    success,
    warning,
    error,
  }
}
