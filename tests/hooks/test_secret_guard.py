import unittest

from tests.hooks.helpers import ALLOWED, BLOCKED, run_hook, run_hook_raw


def fake_aws_key_id():
    # Built from fragments so this file never contains a secret-shaped literal.
    return "AK" + "IA" + "Q" * 16


def fake_private_key():
    return "-----BEGIN " + "RSA PRIVATE" + " KEY-----\nMIIEabc\n-----END RSA PRIVATE KEY-----"


def fake_github_token():
    return "gh" + "p_" + "a1B2" * 9


def guard(tool_name, tool_input):
    return run_hook("secret_guard.py", tool_name, tool_input)


class SecretGuardTest(unittest.TestCase):
    def test_blocks_writing_a_fake_aws_key_to_a_file(self):
        code, stderr = guard("Write", {"file_path": "iac/main.tf", "content": f'key = "{fake_aws_key_id()}"'})
        self.assertEqual(code, BLOCKED)
        self.assertIn("Secret guard", stderr)

    def test_allows_writing_ordinary_terraform(self):
        code, _ = guard("Write", {"file_path": "iac/main.tf", "content": 'name = "orders-api"\n'})
        self.assertEqual(code, ALLOWED)

    def test_blocks_a_private_key_in_an_edit(self):
        code, _ = guard("Edit", {"file_path": "notes.txt", "old_string": "x", "new_string": fake_private_key()})
        self.assertEqual(code, BLOCKED)

    def test_blocks_a_github_token_in_a_shell_command(self):
        code, _ = guard("Bash", {"command": f"export GH_TOKEN={fake_github_token()}"})
        self.assertEqual(code, BLOCKED)

    def test_blocks_a_hardcoded_password_assignment(self):
        content = 'db_pass' + 'word = "' + "Xk82mQp1Lz9w" + '"'
        code, _ = guard("Write", {"file_path": "app.env", "content": content})
        self.assertEqual(code, BLOCKED)

    def test_allows_placeholder_and_variable_assignments(self):
        content = 'password = "<placeholder>"\napi_token = "${API_TOKEN}"\nsecret = "changeme"\n'
        code, _ = guard("Write", {"file_path": "values.yaml", "content": content})
        self.assertEqual(code, ALLOWED)

    def test_blocks_reading_a_dotenv_file(self):
        code, _ = guard("Read", {"file_path": "/repo/.env"})
        self.assertEqual(code, BLOCKED)

    def test_blocks_printing_a_private_key_file_from_the_shell(self):
        code, _ = guard("Bash", {"command": "cat ~/.ssh/id_ed25519"})
        self.assertEqual(code, BLOCKED)

    def test_allows_reading_an_example_env_file(self):
        code, _ = guard("Read", {"file_path": "/repo/.env.example"})
        self.assertEqual(code, ALLOWED)

    def test_allows_ordinary_shell_commands(self):
        code, _ = guard("Bash", {"command": "git status && terraform fmt -check -recursive iac"})
        self.assertEqual(code, ALLOWED)

    def test_blocks_a_secret_inside_a_multi_edit(self):
        edits = [{"old_string": "a", "new_string": "b"}, {"old_string": "c", "new_string": fake_aws_key_id()}]
        code, _ = guard("MultiEdit", {"file_path": "main.tf", "edits": edits})
        self.assertEqual(code, BLOCKED)

    def test_blocks_when_the_event_is_not_valid_json(self):
        code, stderr = run_hook_raw("secret_guard.py", "not json")
        self.assertEqual(code, BLOCKED)
        self.assertIn("Secret guard", stderr)


if __name__ == "__main__":
    unittest.main()
