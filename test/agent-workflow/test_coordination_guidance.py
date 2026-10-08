"""Generated coordination guidance keeps context compact and evidence complete."""
import importlib.util
from pathlib import Path
import re
import tempfile
import tomllib
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('coordination_installer', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ROLES = ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator')


class CoordinationGuidanceContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.policy = {'schema_version': 2, 'source_globs': ['src/**/*.py'],
                       'test_globs': ['test/**']}
        self.files = installer.render(self.root, self.policy)['files']
        self.guide = self.files['.docs/agent-workflow.md']

    def role_instructions(self, platform, role):
        if platform == 'codex':
            return tomllib.loads(self.files[f'.codex/agents/workflow_{role}.toml'])[
                'developer_instructions']
        return self.files[f'.claude/agents/workflow-{role.replace("_", "-")}.md'].split(
            '\n---\n', 1)[1]

    def assert_concepts(self, text, patterns):
        normalized = re.sub(r'\s+', ' ', text).lower()
        for pattern in patterns:
            with self.subTest(concept=pattern):
                self.assertIsNotNone(re.search(pattern, normalized),
                                     f'Missing generated guidance concept: {pattern}')

    def assert_compact_handoff(self, text):
        self.assert_concepts(text, (
            r'compact handoffs?', r'expected behavior', r'owned paths',
            r'relevant (?:repository )?guidance',
            r'accepted.test hashes.{0,60}(?:when available|if available)',
            r'validation commands', r'evidence paths',
            r'(?:report|return|send).{0,60}only.{0,80}completion.{0,80}blockers.{0,80}material findings',
        ))

    def test_shared_guide_defines_complete_compact_handoffs(self):
        self.assert_compact_handoff(self.guide)

    def test_every_native_role_receives_the_handoff_and_reporting_contract(self):
        for platform in ('codex', 'claude'):
            for role in ROLES:
                with self.subTest(platform=platform, role=role):
                    self.assert_compact_handoff(self.role_instructions(platform, role))

    def test_default_coordination_reuses_roles_under_one_main_orchestrator(self):
        for text in (self.guide, self.role_instructions('codex', 'orchestrator'),
                     self.role_instructions('claude', 'orchestrator')):
            self.assert_concepts(text, (
                r'(?:default|normally).{0,100}one main orchestrator.{0,80}(?:one|single) change',
                r'reuse.{0,60}(?:role agents|existing.{0,20}agents)',
            ))

    def test_codex_defaults_to_bounded_context_with_explicit_task_context(self):
        for text in (self.guide, self.role_instructions('codex', 'orchestrator')):
            self.assert_concepts(text, (
                r'bounded context', r'explicit task context',
                r'(?:avoid|no|without|do not use).{0,50}full.history fork.{0,60}(?:default|normally)',
                r'full.history fork.{0,80}only.{0,60}(?:needed|necessary|required)',
            ))

    def test_compact_reports_preserve_full_evidence_and_independent_reading(self):
        for text in (self.guide, self.role_instructions('codex', 'runner'),
                     self.role_instructions('claude', 'runner'),
                     self.role_instructions('codex', 'reviewer'),
                     self.role_instructions('claude', 'reviewer')):
            self.assert_concepts(text, (
                r'(?:retain|preserve|keep|record).{0,60}full evidence',
                r'independent reviewer.{0,80}(?:read|inspect).{0,60}(?:full evidence|evidence (?:files|artifacts))',
            ))

    def test_existing_pipeline_ownership_security_and_pr_evidence_remain(self):
        self.assert_concepts(self.guide, (
            r'orchestrator defines expected behavior; spec writer writes tests; runner demonstrates the expected failure;',
            r'reviewer accepts the tests before implementation; implementer changes code; runner verifies green; reviewer independently checks implementation and final diff',
            r'never weaken an accepted test', r'renewed reviewer acceptance',
            r'record hashes of accepted tests before implementation and compare afterward',
            r'spec writer owns edits to matched tests and test fixtures',
            r'implementer owns edits to matched source files, excluding matched tests',
            r'runner, reviewer, orchestrator and parent sessions do not edit source or tests',
            r'every agent review must check and explicitly report security advisories',
            r'including pre.existing findings unrelated to the current diff',
            r'names or links alone are insufficient', r'never fabricate output',
            r'focused evidence does not replace required full quality gates',
            r'no model is selected',
        ))
        for platform in ('codex', 'claude'):
            reviewer = self.role_instructions(platform, 'reviewer')
            self.assert_concepts(reviewer, (
                r'always check and report security advisories', r'pre.existing findings',
                r'actual ruby rspec --format documentation or elixir exunit --trace output',
                r'names or links alone are insufficient acceptance evidence',
                r'never accept fabricated output',
            ))
            for role in ROLES:
                instructions = self.role_instructions(platform, role)
                restriction = 'do not edit source' if role == 'spec_writer' else (
                    'do not edit tests' if role == 'implementer' else 'do not edit source or tests')
                self.assertIn(restriction, instructions.lower())
        for platform in ('codex', 'claude'):
            for name in ('workflow_guard.py', 'workflow_audit.py'):
                self.assertEqual((BASE / name).read_text(), self.files[f'.{platform}/hooks/{name}'])


if __name__ == '__main__':
    unittest.main()
