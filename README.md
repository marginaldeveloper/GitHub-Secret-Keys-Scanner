# GitHub Secrets Scanner

## **Overview**

The **GitHub Secrets Scanner** is a Bash script designed to scan GitHub repositories for sensitive information such as API keys and secrets. It utilizes GitHub's API to fetch repositories and organizations associated with provided access tokens, clones the repositories, and searches for specific patterns that may indicate the presence of sensitive data. The results are logged and organized into designated directories for further analysis.

## **Features**

- **Batch Processing**: Processes multiple GitHub access tokens in batches for efficiency.
- **Parallel Execution**: Utilizes GNU Parallel to run multiple scans concurrently, improving performance.
- **Error Handling**: Logs errors encountered during API calls and repository cloning.
- **Pattern Matching**: Searches for predefined patterns that may indicate sensitive information, such as API keys and secrets.
- **Results Organization**: Saves results in structured directories for easy access and review.

## **Requirements**

- **Bash shell**
- **curl** for making API requests
- **jq** for parsing JSON responses
- **git** for cloning repositories
- **grep** for searching files
- **parallel** for concurrent processing

## **Setup**

1. **Clone the Repository**: Clone this repository to your local machine.
2. **Install Dependencies**: Ensure that `curl`, `jq`, `git`, `grep`, and `parallel` are installed on your system.
3. **Prepare Input File**: Create a file named `githubvalid` in the same directory as the script, containing one GitHub access token per line.

## **Usage**

1. **Run the Script**: Execute the script in your terminal:

   ```bash
   ./scan.sh
