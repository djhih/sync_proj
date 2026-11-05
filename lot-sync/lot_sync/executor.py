"""Turns a plan into effects, or just reports it when dry-running."""
import logging
import os
import shutil
from collections import Counter
from dataclasses import dataclass, field
from typing import Iterable, Optional

from .plan import Action, Kind
from .problems import ProblemLog
from .rsync import Rsync, RsyncError
from .state import SyncState


@dataclass
class Report:
    applied: int = 0
    skipped: int = 0
    up_to_date: int = 0
    duplicates: int = 0
    failed: int = 0
    skip_reasons: Counter = field(default_factory=Counter)

    @property
    def ok(self) -> bool:
        return self.failed == 0 and self.duplicates == 0

    def summary(self, dry_run: bool = False) -> str:
        applied = "would_apply" if dry_run else "applied"
        reasons = ", ".join("{}: {}".format(r, n) for r, n in sorted(self.skip_reasons.items()))
        return "{}={} up_to_date={} skipped={}{} duplicates={} failed={}".format(
            applied, self.applied, self.up_to_date, self.skipped,
            " [{}]".format(reasons) if reasons else "", self.duplicates, self.failed)


def partial_path(destination: str) -> str:
    return os.path.join(os.path.dirname(destination),
                        ".{}.partial".format(os.path.basename(destination)))


class Executor:
    def __init__(self, dry_run: bool, rsync: Optional[Rsync] = None,
                 state: Optional[SyncState] = None, verify: bool = True):
        self._dry_run = dry_run
        self._rsync = rsync
        self._state = state
        self._verify = verify

    def run(self, actions: Iterable[Action]) -> Report:
        report = Report()
        reported = self._state.reported if self._state else set()
        problems = ProblemLog(reported, repeat_all=self._dry_run)
        for action in actions:
            self._handle(action, report, problems)
        self._remember_problems(problems)
        return report

    def _remember_problems(self, problems: ProblemLog) -> None:
        if self._state is None or self._dry_run or self._state.reported == problems.current:
            return
        self._state.reported = problems.current
        self._state.save()

    def _handle(self, action: Action, report: Report, problems: ProblemLog) -> None:
        if action.kind is Kind.UP_TO_DATE:
            report.up_to_date += 1
            logging.debug("%s", action.describe())
        elif action.kind is Kind.SKIP:
            report.skipped += 1
            report.skip_reasons[action.reason] += 1
            logging.log(logging.INFO if self._dry_run else logging.DEBUG,
                        "%s", action.describe())
        elif action.kind is Kind.DUPLICATE:
            report.duplicates += 1
            problems.report(action.problem_key(), "DUPLICATE LOT | " + action.describe())
        elif action.kind is Kind.ERROR:
            report.failed += 1
            problems.report(action.problem_key(), "PLAN FAILED | " + action.describe())
        elif self._dry_run:
            report.applied += 1
            logging.info("DRY-RUN | %s", action.describe())
            self._log_replacements("DRY-RUN REPLACE", action)
        else:
            self._apply(action, report, problems)

    def _apply(self, action: Action, report: Report, problems: ProblemLog) -> None:
        handlers = {
            Kind.COPY_TREE: self._copy_tree,
            Kind.COPY_FILE: self._copy_file,
            Kind.MOVE: self._move,
        }
        logging.info("START | %s", action.describe())
        self._log_replacements("REPLACING", action)  # logged first: a record even if the copy dies
        try:
            handlers[action.kind](action)
        except (OSError, RsyncError) as error:
            report.failed += 1
            problems.report("FAILED|" + action.src,
                            "FAILED | {}: {}".format(action.describe(), error))
        else:
            report.applied += 1
            logging.info("DONE | %s", action.describe())

    @staticmethod
    def _log_replacements(label: str, action: Action) -> None:
        for note in action.notes:
            logging.info("%s | %s", label, note)

    def _copy_tree(self, action: Action) -> None:
        destination = action.dst
        # A new folder is built aside and renamed, so readers never see half of it.
        # An existing one is brought up to date in place (late files, interrupted runs).
        staging = destination if os.path.isdir(destination) else partial_path(destination)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        self._rsync.copy_tree(action.src, staging)
        if self._verify:
            self._rsync.verify_tree(action.src, staging)
        if staging != destination:
            os.rename(staging, destination)
        self._state.mark_done(action.dst, action.src, action.signature)
        self._state.save()

    def _copy_file(self, action: Action) -> None:
        destination = action.dst
        staging = partial_path(destination)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        try:
            shutil.copy2(action.src, staging)
            os.replace(staging, destination)
        finally:
            if os.path.exists(staging):
                os.remove(staging)

    def _move(self, action: Action) -> None:
        if os.path.lexists(action.dst):
            raise FileExistsError(action.dst)
        os.makedirs(os.path.dirname(action.dst), exist_ok=True)
        os.rename(action.src, action.dst)
