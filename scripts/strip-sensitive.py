#!/usr/bin/env python3
"""
strip-sensitive.py - Strip PII and secrets from code/logs before sharing with external LLMs.

Usage:
    ./strip-sensitive.py <input_file> [output_file]
    cat file.log | ./strip-sensitive.py -
    ./strip-sensitive.py input.txt output.txt --config custom_config.json

Features:
    - Strips API keys, tokens, passwords
    - Redacts email addresses, phone numbers
    - Masks IP addresses (internal/private ranges)
    - Replaces MAC addresses
    - Removes proprietary project names (configurable)
    - Handles common log formats
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple, Union


# Default configuration
DEFAULT_CONFIG = {
    # Proprietary project names to redact (add your own)
    "project_names": [
        "linksys",
        "velop",
        "cognio",
        "wrt",
    ],
    # Custom keywords to redact
    "custom_keywords": [],
    # Replacement placeholders
    "placeholders": {
        "email": "[EMAIL_REDACTED]",
        "phone": "[PHONE_REDACTED]",
        "ip_private": "[INTERNAL_IP]",
        "ip_public": "[IP_REDACTED]",
        "mac": "[MAC_REDACTED]",
        "api_key": "[API_KEY_REDACTED]",
        "password": "[PASSWORD_REDACTED]",
        "token": "[TOKEN_REDACTED]",
        "secret": "[SECRET_REDACTED]",
        "ssn": "[SSN_REDACTED]",
        "credit_card": "[CC_REDACTED]",
        "project": "[PROJECT_REDACTED]",
        "hostname": "[HOSTNAME_REDACTED]",
        "username": "[USER_REDACTED]",
        "path": "[PATH_REDACTED]",
    },
}


class SensitiveDataStripper:
    """Strip sensitive data from text content."""

    def __init__(self, config: Optional[Dict] = None):
        self.config = {**DEFAULT_CONFIG, **(config or {})}
        self.placeholders = self.config["placeholders"]
        self.stats = {key: 0 for key in self.placeholders}

    def _compile_patterns(self) -> List[Tuple[re.Pattern, Union[str, Callable]]]:
        """Compile regex patterns for sensitive data detection."""
        patterns = []

        # API Keys and Tokens (common formats)
        api_key_patterns = [
            # Generic API key patterns
            r'(?i)(api[_-]?key|apikey)\s*[=:]\s*["\']?([a-zA-Z0-9_\-]{20,})["\']?',
            r'(?i)(access[_-]?token|auth[_-]?token)\s*[=:]\s*["\']?([a-zA-Z0-9_\-\.]{20,})["\']?',
            # AWS
            r'AKIA[0-9A-Z]{16}',
            r'(?i)aws[_-]?secret[_-]?access[_-]?key\s*[=:]\s*["\']?([a-zA-Z0-9/+=]{40})["\']?',
            # GitHub
            r'ghp_[a-zA-Z0-9]{36}',
            r'gho_[a-zA-Z0-9]{36}',
            r'ghs_[a-zA-Z0-9]{36}',
            r'ghr_[a-zA-Z0-9]{36}',
            # Slack
            r'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}',
            # Generic long alphanumeric (likely tokens)
            r'(?i)(bearer|token)\s+[a-zA-Z0-9_\-\.]{20,}',
        ]
        for pattern in api_key_patterns:
            patterns.append((re.compile(pattern), self.placeholders["api_key"]))

        # Passwords in various formats
        password_patterns = [
            r'(?i)(password|passwd|pwd)\s*[=:]\s*["\']?([^\s"\']{1,})["\']?',
            r'(?i)(password|passwd|pwd)\s*[=:]\s*["\']([^"\']+)["\']',
        ]
        for pattern in password_patterns:
            patterns.append((re.compile(pattern), self._mask_password))

        # Secrets
        secret_patterns = [
            r'(?i)(secret|private[_-]?key)\s*[=:]\s*["\']?([^\s"\']{8,})["\']?',
            r'-----BEGIN (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----',
            r'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',
        ]
        for pattern in secret_patterns:
            patterns.append((re.compile(pattern), self.placeholders["secret"]))

        # Email addresses
        patterns.append((
            re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'),
            self.placeholders["email"]
        ))

        # Phone numbers (various formats)
        phone_patterns = [
            r'\+?1?[-.\s]?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}',
            r'\+[0-9]{1,3}[-.\s]?[0-9]{1,4}[-.\s]?[0-9]{1,4}[-.\s]?[0-9]{1,9}',
        ]
        for pattern in phone_patterns:
            patterns.append((re.compile(pattern), self.placeholders["phone"]))

        # SSN
        patterns.append((
            re.compile(r'\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b'),
            self.placeholders["ssn"]
        ))

        # Credit card numbers
        patterns.append((
            re.compile(r'\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\b'),
            self.placeholders["credit_card"]
        ))

        # MAC addresses
        patterns.append((
            re.compile(r'(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'),
            self.placeholders["mac"]
        ))

        # IP addresses (handled specially for private vs public)
        patterns.append((
            re.compile(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b'),
            self._mask_ip
        ))

        # IPv6 addresses
        patterns.append((
            re.compile(r'(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'),
            self.placeholders["ip_public"]
        ))

        # Hostnames that look internal
        patterns.append((
            re.compile(r'\b[a-zA-Z0-9][-a-zA-Z0-9]*\.(internal|local|corp|lan|home)\b', re.IGNORECASE),
            self.placeholders["hostname"]
        ))

        # Unix-style paths with usernames
        patterns.append((
            re.compile(r'/(?:home|Users)/[a-zA-Z0-9_-]+'),
            self._mask_user_path
        ))

        # Windows-style user paths
        patterns.append((
            re.compile(r'C:\\Users\\[a-zA-Z0-9_-]+', re.IGNORECASE),
            self._mask_user_path
        ))

        # Project names (case insensitive)
        for project in self.config["project_names"]:
            if project:
                patterns.append((
                    re.compile(rf'\b{re.escape(project)}\b', re.IGNORECASE),
                    self.placeholders["project"]
                ))

        # Custom keywords
        for keyword in self.config["custom_keywords"]:
            if keyword:
                patterns.append((
                    re.compile(rf'\b{re.escape(keyword)}\b', re.IGNORECASE),
                    self.placeholders["project"]
                ))

        return patterns

    def _mask_password(self, match: re.Match) -> str:
        """Mask password while keeping the key name."""
        self.stats["password"] += 1
        key = match.group(1)
        return f'{key}={self.placeholders["password"]}'

    def _mask_ip(self, match: re.Match) -> str:
        """Mask IP addresses, distinguishing private from public."""
        ip = match.group(0)
        octets = [int(o) for o in ip.split('.')]

        # Check if private IP
        is_private = (
            octets[0] == 10 or
            (octets[0] == 172 and 16 <= octets[1] <= 31) or
            (octets[0] == 192 and octets[1] == 168) or
            octets[0] == 127
        )

        if is_private:
            self.stats["ip_private"] += 1
            return self.placeholders["ip_private"]
        else:
            self.stats["ip_public"] += 1
            return self.placeholders["ip_public"]

    def _mask_user_path(self, match: re.Match) -> str:
        """Mask user paths while keeping structure visible."""
        self.stats["path"] += 1
        path = match.group(0)
        if path.startswith('/home/') or path.startswith('/Users/'):
            return f'{path.split("/")[0]}/{path.split("/")[1]}/{self.placeholders["username"]}'
        else:
            return f'C:\\Users\\{self.placeholders["username"]}'

    def strip(self, text: str) -> str:
        """Strip all sensitive data from text."""
        patterns = self._compile_patterns()

        result = text
        for pattern, replacement in patterns:
            if callable(replacement):
                result = pattern.sub(replacement, result)
            else:
                count = len(pattern.findall(result))
                if count > 0:
                    # Update stats for this placeholder type
                    for key, placeholder in self.placeholders.items():
                        if placeholder == replacement:
                            self.stats[key] += count
                            break
                result = pattern.sub(replacement, result)

        return result

    def get_stats(self) -> Dict:
        """Get redaction statistics."""
        return {k: v for k, v in self.stats.items() if v > 0}


def load_config(config_path: Optional[str]) -> Dict:
    """Load configuration from JSON file."""
    if config_path and Path(config_path).exists():
        with open(config_path) as f:
            return json.load(f)
    return {}


def main():
    parser = argparse.ArgumentParser(
        description="Strip PII and secrets from code/logs before sharing with external LLMs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    %(prog)s input.log output.log
    cat server.log | %(prog)s - > clean.log
    %(prog)s code.py --config my_config.json
    %(prog)s input.txt -o output.txt --add-project "MySecretProject"
        """
    )
    parser.add_argument("input", help="Input file path or '-' for stdin")
    parser.add_argument("output", nargs="?", help="Output file path (default: stdout)")
    parser.add_argument("-o", "--output-file", help="Output file path (alternative)")
    parser.add_argument("-c", "--config", help="Path to JSON config file")
    parser.add_argument("--add-project", action="append", default=[],
                        help="Add project name to redact (can be used multiple times)")
    parser.add_argument("--add-keyword", action="append", default=[],
                        help="Add custom keyword to redact (can be used multiple times)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Print redaction statistics to stderr")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be redacted without making changes")

    args = parser.parse_args()

    # Load configuration
    config = load_config(args.config)

    # Add command-line project names and keywords
    if args.add_project:
        config.setdefault("project_names", DEFAULT_CONFIG["project_names"].copy())
        config["project_names"].extend(args.add_project)
    if args.add_keyword:
        config.setdefault("custom_keywords", [])
        config["custom_keywords"].extend(args.add_keyword)

    # Read input
    if args.input == "-":
        text = sys.stdin.read()
    else:
        input_path = Path(args.input)
        if not input_path.exists():
            print(f"Error: Input file not found: {args.input}", file=sys.stderr)
            sys.exit(1)
        text = input_path.read_text()

    # Strip sensitive data
    stripper = SensitiveDataStripper(config)
    result = stripper.strip(text)

    # Output
    output_path = args.output_file or args.output
    if args.dry_run:
        stats = stripper.get_stats()
        print("Dry run - would redact:", file=sys.stderr)
        for key, count in stats.items():
            print(f"  {key}: {count} occurrences", file=sys.stderr)
    elif output_path:
        Path(output_path).write_text(result)
        if args.verbose:
            print(f"Output written to: {output_path}", file=sys.stderr)
    else:
        print(result)

    # Print statistics
    if args.verbose:
        stats = stripper.get_stats()
        if stats:
            print("\nRedaction statistics:", file=sys.stderr)
            for key, count in stats.items():
                print(f"  {key}: {count}", file=sys.stderr)


if __name__ == "__main__":
    main()
