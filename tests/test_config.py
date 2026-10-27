"""Config loading: what is opt-in, what is fatal, and what resolves by itself.

Providers are explicit here, so the interesting cases are all about a config
that names something wrong -- an install that silently searches a provider its
operator never asked for is the failure mode this version exists to remove. A
config that names *nothing* is the third case and no longer an error: it is the
keyless set, which is the one set an install can enable without being told
anything.
"""

import re
import tomllib
from pathlib import Path

import pytest
from pydantic import ValidationError

from seekwright.config import (
    FREE_PROVIDER_ORDER,
    FREE_PROVIDERS,
    KEYLESS_PROVIDERS,
    KNOWN_PROVIDERS,
    PROVIDERS_REQUIRING_KEY,
    UNTESTED_PROVIDERS,
    AgentConfig,
    Config,
    DashboardConfig,
    FetchConfig,
    LoggingConfig,
    ProviderConfig,
    SearchConfig,
    api_key_env_var,
    load_config,
)
from seekwright.fetcher import KNOWN_FALLBACKS


def write(tmp_path, text: str):
    path = tmp_path / "config.toml"
    path.write_text(text)
    return path


class TestProviderOptIn:
    """Opt-in stays opt-in; what changed is what the empty set resolves to.

    A config that enables nothing used to be a startup error. It is now the
    keyless set -- `exa:free`, `parallel:free` and `freeserp` -- because those
    are the only names that need nothing from the operator and cannot bill, so
    the install works on first run without the operator writing config first.
    Everything that named something still behaves exactly as it did; an
    explicit set is never widened by the default.
    """

    def test_a_config_naming_no_provider_is_the_keyless_set(self, tmp_path):
        path = write(tmp_path, "[policy]\nmax_snippet_chars = 100\n")

        cfg = load_config(path)

        assert cfg.enabled_providers() == ["exa:free", "freeserp", "parallel:free"]
        assert cfg.providers_defaulted is True

    def test_a_missing_config_file_is_the_keyless_set(self, tmp_path):
        """No config file at all is the first run, and it works."""
        cfg = load_config(tmp_path / "nope.toml")

        assert cfg.enabled_providers() == ["exa:free", "freeserp", "parallel:free"]
        assert cfg.providers_defaulted is True

    def test_a_provider_disabled_leaves_the_keyless_set(self, tmp_path):
        path = write(tmp_path, "[providers.serper]\nenabled = false\n")

        cfg = load_config(path)

        assert cfg.enabled_providers() == ["exa:free", "freeserp", "parallel:free"]
        assert cfg.providers_defaulted is True

    def test_the_implicit_set_is_marked_as_implicit(self, tmp_path):
        """The startup line and `--check` read this; silence is what is refused."""
        assert load_config(tmp_path / "nope.toml").providers_defaulted is True

        named = load_config(write(tmp_path, "[providers.serper]\nenabled = true\n"))

        assert named.providers_defaulted is False

    def test_a_config_naming_something_wrong_still_names_the_file(self, tmp_path):
        """The old error survives where it belongs: a config that named
        something and could not build it."""
        path = write(tmp_path, "[providers.serper]\nenabledd = true\n")

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert str(path) in str(exc.value)

    def test_a_misspelled_provider_is_a_startup_error(self, tmp_path):
        """Typos must not resolve to an empty set that looks like a config choice."""
        path = write(tmp_path, "[providers.serpr]\nenabled = true\n")
        with pytest.raises(SystemExit, match="unknown provider"):
            load_config(path)

    def test_a_named_provider_is_loaded(self, tmp_path):
        cfg = load_config(write(tmp_path, "[providers.serper]\nenabled = true\n"))
        assert cfg.enabled_providers() == ["serper"]

    def test_a_quoted_flavoured_table_loads_and_enables(self, tmp_path):
        """`backend:flavour` round-trips: the table is quoted (rule 1) and the
        provider is a real, enabled name once the file is parsed."""
        path = write(tmp_path, '[providers."exa:free"]\nenabled = true\n')

        cfg = load_config(path)

        assert cfg.enabled_providers() == ["exa:free"]
        assert cfg.default_provider == "exa:free"

    def test_an_unquoted_flavoured_table_is_a_toml_error(self, tmp_path):
        """The reason the quoting is not optional: `:` ends a bare TOML key, so
        `[providers.exa:free]` never parses. Pinned here rather than only in the
        docs, because it is what an operator's first attempt looks like."""
        path = write(tmp_path, "[providers.exa:free]\nenabled = true\n")
        with pytest.raises(SystemExit, match="invalid TOML"):
            load_config(path)

    def test_a_renamed_provider_names_its_replacement(self, tmp_path):
        """A rename is hard -- there is no alias -- so the error has to say what
        the name became. The supported list alone is the one thing that sends an
        operator hunting, because the name they wrote is not a typo."""
        path = write(tmp_path, "[providers.exa_free]\nenabled = true\n")

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert "unknown provider(s) exa_free" in str(exc.value)
        assert 'it is now "exa:free"' in str(exc.value)


class TestTheFreeOnlyDefaultRoute:
    """The rule behind both the engine's substitution and `--check`'s `default`
    line, asserted here once so the two cannot disagree about it.

    It is a *ceiling of zero* test, not a price test: `tinyfish` is free at any
    balance and is in; `tavily` has a free tier and can still bill, so it is
    out. "Has a free tier" is the line this set deliberately does not draw: the
    question is whether a call can bill, not whether a tier is free.
    """

    def test_the_keyless_default_is_free_only(self):
        assert Config().default_route_is_free_only() is True

    def test_free_names_only_is_free_only(self):
        cfg = Config(
            providers={
                "exa:free": ProviderConfig(),
                "tinyfish": ProviderConfig(),
            }
        )
        assert cfg.default_route_is_free_only() is True

    def test_one_name_that_can_bill_is_not(self):
        cfg = Config(
            providers={"exa:free": ProviderConfig(), "serper": ProviderConfig()}
        )
        assert cfg.default_route_is_free_only() is False

    def test_a_free_tier_is_not_a_free_name(self):
        cfg = Config(
            providers={"exa:free": ProviderConfig(), "tavily": ProviderConfig()}
        )
        assert cfg.default_route_is_free_only() is False

    def test_a_lone_free_provider_is_the_default_not_a_walk(self):
        """The walk is for the case with no default; a lone provider gets one."""
        cfg = Config(providers={"exa:free": ProviderConfig()})

        assert cfg.default_provider == "exa:free"
        assert cfg.default_route_is_free_only() is True


class TestDefaultProvider:
    def test_a_single_provider_becomes_the_default(self):
        cfg = Config(providers={"serper": ProviderConfig()})
        assert cfg.default_provider == "serper"

    def test_several_providers_leave_the_default_unset(self):
        """Choosing for the caller would spend at a price they never agreed to."""
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()}
        )
        assert cfg.default_provider is None

    def test_an_explicit_default_is_kept(self):
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            default_provider="linkup",
        )
        assert cfg.default_provider == "linkup"

    def test_a_default_that_is_not_enabled_is_rejected(self):
        with pytest.raises(ValidationError):
            Config(
                providers={"serper": ProviderConfig()},
                default_provider="linkup",
            )


class TestPermittedProviders:
    """The allow-list: a permission set, not a second `enabled`.

    Deny-by-default once declared, `enabled ∩ permitted` as the effective set,
    and unset is permissive -- so no config written before this key existed
    changes behaviour. The three rules are fixed by
    docs/reference/allow-list.md.
    """

    def test_unset_is_permissive(self):
        cfg = Config(providers={"serper": ProviderConfig()})
        assert cfg.permitted_providers is None
        assert cfg.is_permitted("linkup"), "no key means every name is permitted"
        assert cfg.effective_providers() == ["serper"]

    def test_a_valid_list_loads_and_narrows(self):
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            permitted_providers=["serper"],
        )
        assert cfg.permitted_providers == ["serper"]
        assert cfg.is_permitted("serper")
        assert not cfg.is_permitted("linkup")
        assert cfg.effective_providers() == ["serper"]

    def test_membership_never_enables(self):
        """`enabled ∩ permitted`, both directions: a permitted name with no
        table is not dispatched, and an enabled name the list omits is not."""
        cfg = Config(
            providers={"serper": ProviderConfig(), "linkup": ProviderConfig()},
            permitted_providers=["serper", "tavily"],
        )
        assert cfg.is_permitted("tavily")
        assert "tavily" not in cfg.effective_providers()
        assert cfg.effective_providers() == ["serper"]

    def test_a_known_but_not_enabled_name_loads(self, tmp_path):
        """A normal state, not a typo: the set is written once and providers are
        turned on and off under it, which is the intersection working."""
        path = write(
            tmp_path,
            'permitted_providers = ["serper", "tavily"]\n'
            "[providers.serper]\nenabled = true\n",
        )
        cfg = load_config(path)
        assert cfg.permitted_providers == ["serper", "tavily"]
        assert cfg.effective_providers() == ["serper"]

    def test_an_unknown_name_is_a_startup_error(self, tmp_path):
        path = write(
            tmp_path,
            'permitted_providers = ["kagi"]\n'
            "[providers.serper]\nenabled = true\n",
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        message = str(exc.value)
        assert "permitted_providers names unknown provider(s) kagi" in message
        assert "supported: " in message

    def test_the_fetch_only_name_is_admissible(self):
        """`jina` is not a provider name, so a set that has to vouch for the
        keyless fetch fallback names it through `PERMITTED_FETCH_NAMES`:
        membership succeeds, nothing is enabled by it, and the unknown-name
        error's supported list offers it."""
        cfg = Config(
            providers={"serper": ProviderConfig()},
            permitted_providers=["serper", "jina"],
        )
        assert cfg.is_permitted("jina") is True
        assert cfg.effective_providers() == ["serper"], "membership never enables"

        with pytest.raises(ValidationError) as exc:
            Config(
                providers={"serper": ProviderConfig()},
                permitted_providers=["serper", "jina", "kagi"],
            )

        message = str(exc.value)
        assert "unknown provider(s) kagi" in message
        assert "jina" in message.split("supported: ", 1)[1], (
            "the fetch-only name is one of the names the error offers"
        )

    def test_a_retired_spelling_names_its_replacement(self, tmp_path):
        path = write(
            tmp_path,
            'permitted_providers = ["exa_free"]\n'
            "[providers.serper]\nenabled = true\n",
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert 'it is now "exa:free"' in str(exc.value)

    def test_a_duplicate_is_a_startup_error(self, tmp_path):
        """A permission set with a duplicate is a list the operator mis-wrote."""
        path = write(
            tmp_path,
            'permitted_providers = ["serper", "serper"]\n'
            "[providers.serper]\nenabled = true\n",
        )

        with pytest.raises(SystemExit, match="more than once"):
            load_config(path)

    def test_a_wildcard_list_reads_as_unset(self):
        """`"*"` is not a provider name, so it cannot be a member, and a list
        whose meaning is "everything" is the same list as no list at all --
        which is why nothing else in it is validated either."""
        cfg = Config(
            providers={"serper": ProviderConfig()},
            permitted_providers=["*", "kagi"],
        )
        assert cfg.permitted_providers is None
        assert cfg.is_permitted("linkup")
        assert cfg.effective_providers() == ["serper"]

    def test_an_empty_list_declares_an_empty_permission_set(self):
        """The reading this implementation took: "unset is permissive" is about
        the *absent* key, and `[]` is not the absent key, so every name is
        outside the declared set. `--check`'s `effective` line is what makes
        that state loud rather than silent."""
        cfg = Config(providers={"serper": ProviderConfig()}, permitted_providers=[])

        assert cfg.permitted_providers == []
        assert not cfg.is_permitted("serper")
        assert cfg.effective_providers() == []

    def test_a_host_value_is_not_a_provider(self, tmp_path):
        """`--allowed-host` decides which names this service *answers to*; this
        key decides which providers it dispatches to, and the two sets do not
        overlap -- so a Host value here is an unknown provider."""
        path = write(
            tmp_path,
            'permitted_providers = ["localhost"]\n'
            "[providers.serper]\nenabled = true\n",
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert "unknown provider(s) localhost" in str(exc.value)


class TestPolicy:
    def test_context_bounds_have_working_defaults(self):
        """Both caps ship on: an operator who writes no [policy] block still
        gets a bounded response, which is the whole point of them."""
        cfg = Config(providers={"exa": ProviderConfig()})
        assert cfg.policy.max_snippet_chars == 500
        assert cfg.policy.max_result_text_chars == 2000

    def test_both_content_switches_are_off_by_default(self):
        """Neither the caller's text nor the provider's is kept unless asked."""
        cfg = Config(providers={"exa": ProviderConfig()})
        assert cfg.logging.log_queries is False
        assert cfg.logging.log_content is False

    def test_the_text_cap_is_configurable(self, tmp_path):
        path = write(
            tmp_path,
            "[providers.exa]\nenabled = true\n"
            "[policy]\nmax_result_text_chars = 800\n",
        )
        assert load_config(path).policy.max_result_text_chars == 800


class TestFetchExtractor:
    """The extraction backend is a config choice, not a hardcoded function."""

    def test_the_default_backend_is_trafilatura(self):
        assert FetchConfig().extractor == "trafilatura"

    def test_the_standard_library_backend_is_accepted(self):
        """`KNOWN_EXTRACTORS` carries a second name, and the validator reads that
        set rather than a copy of it."""
        assert FetchConfig(extractor="stdlib").extractor == "stdlib"

    def test_an_unknown_backend_is_rejected_naming_the_supported_set(self):
        with pytest.raises(ValidationError, match="readability"):
            FetchConfig(extractor="readability")

        with pytest.raises(ValidationError, match="trafilatura"):
            FetchConfig(extractor="readability")


class TestApiKeys:
    def test_a_keyless_provider_is_reported(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_SERPER_API_KEY", raising=False)
        cfg = Config(providers={"serper": ProviderConfig()})
        assert cfg.missing_api_keys() == ["serper"]

    def test_a_flavoured_name_needs_no_key(self, monkeypatch):
        """The anonymous half of Exa's MCP endpoint: a rate-limited free plan,
        and the only provider that works with nothing configured."""
        monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        cfg = Config(providers={"exa:free": ProviderConfig()})
        assert cfg.missing_api_keys() == []

    def test_a_flavoured_name_reads_its_backend_key(self, monkeypatch):
        """`:` is not legal in a POSIX variable name, so the key is the
        backend's: a key names the *account*, the flavour names the *route*
        through it."""
        monkeypatch.setenv("SEEKWRIGHT_EXA_API_KEY", "k")
        cfg = Config(providers={"exa:free": ProviderConfig()})
        assert cfg.api_key("exa:free") == "k"
        assert cfg.missing_api_keys() == []

    def test_the_variable_is_named_for_the_backend(self):
        """The one derivation every site prints through, so the two
        operator-facing messages cannot drift from `api_key`: `--check`'s line
        and `server.main`'s missing-key check both build their text from
        `api_key_env_var`, not from the name whole."""
        assert api_key_env_var("exa") == "SEEKWRIGHT_EXA_API_KEY"
        assert api_key_env_var("exa:free") == "SEEKWRIGHT_EXA_API_KEY"
        assert api_key_env_var("parallel:free") == "SEEKWRIGHT_PARALLEL_API_KEY"

    def test_exa_does_need_a_key(self, monkeypatch):
        """`exa` is the billed half of the same endpoint. Without a key it would
        silently be `exa:free` under a name that says otherwise."""
        monkeypatch.delenv("SEEKWRIGHT_EXA_API_KEY", raising=False)
        cfg = Config(providers={"exa": ProviderConfig()})
        assert cfg.missing_api_keys() == ["exa"]

    def test_a_keyed_provider_is_not_reported(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        cfg = Config(providers={"serper": ProviderConfig()})
        assert cfg.missing_api_keys() == []

    def test_a_disabled_provider_needs_no_key(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_LINKUP_API_KEY", raising=False)
        monkeypatch.setenv("SEEKWRIGHT_SERPER_API_KEY", "k")
        cfg = Config(
            providers={
                "serper": ProviderConfig(),
                "linkup": ProviderConfig(enabled=False),
            }
        )
        assert cfg.missing_api_keys() == []


class TestLoggingConfig:
    def test_defaults_are_the_quiet_private_ones(self):
        cfg = LoggingConfig()
        assert cfg.level == "INFO"
        # Text, because the default transport is stdio, where stderr lands in a
        # client's log file that a person reads.
        assert cfg.format == "text"
        assert cfg.log_queries is False
        assert cfg.access_log is False
        assert cfg.library_level == "WARNING"

    def test_a_config_without_the_section_still_gets_one(self, tmp_path, monkeypatch):
        path = tmp_path / "config.toml"
        path.write_text("[providers.serper]\nenabled = true\n")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))
        assert load_config().logging.level == "INFO"

    def test_the_section_is_read(self, tmp_path, monkeypatch):
        path = tmp_path / "config.toml"
        path.write_text(
            "[providers.serper]\nenabled = true\n\n"
            '[logging]\nlevel = "DEBUG"\nformat = "json"\nlog_queries = true\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))
        cfg = load_config().logging
        assert (cfg.level, cfg.format, cfg.log_queries) == ("DEBUG", "json", True)

    def test_a_bad_level_names_the_offending_file(self, tmp_path, monkeypatch):
        path = tmp_path / "config.toml"
        path.write_text(
            '[providers.serper]\nenabled = true\n\n[logging]\nlevel = "LOUD"\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))
        with pytest.raises(SystemExit) as exc:
            load_config()
        assert str(path) in str(exc.value)


class TestDashboardSection:
    """The dashboard ships on, with no journal until the operator names one."""

    def test_defaults(self):
        cfg = DashboardConfig()
        assert cfg.enabled is True
        assert cfg.history_path is None

    def test_a_config_without_the_section_still_gets_one(self, tmp_path, monkeypatch):
        path = tmp_path / "config.toml"
        path.write_text("[providers.serper]\nenabled = true\n")
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))
        assert load_config().dashboard.enabled is True

    def test_the_section_is_read(self, tmp_path, monkeypatch):
        path = tmp_path / "config.toml"
        path.write_text(
            "[providers.serper]\nenabled = true\n\n"
            '[dashboard]\nenabled = false\nhistory_path = "/tmp/usage.jsonl"\n'
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))
        cfg = load_config().dashboard
        assert cfg.enabled is False
        assert cfg.history_path == "/tmp/usage.jsonl"


class TestUnknownKeys:
    """A key this server does not have is an error, not a shrug.

    pydantic ignores unknown fields by default, which for a config file is the
    worst option available: `max_snipet_chars = 50` parses, validates, loads and
    does nothing, and the only way to find out is to notice the setting never
    took effect. Provider *names* were already checked for exactly this reason;
    these pin the same rule for key names.
    """

    @pytest.mark.parametrize(
        "section,text",
        [
            ("top level", "notakey = 1\n"),
            ("policy", "[policy]\nmax_snipet_chars = 50\n"),
            ("fetch", "[fetch]\nmax_text_charts = 100\n"),
            ("logging", "[logging]\nlevl = \"DEBUG\"\n"),
            ("dashboard", "[dashboard]\nenabledd = true\n"),
            ("provider", "[providers.serper]\nenabledd = true\n"),
        ],
    )
    def test_a_typo_is_a_startup_error(self, tmp_path, monkeypatch, section, text):
        path = write(tmp_path, "[providers.serper]\nenabled = true\n\n" + text)
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))

        with pytest.raises(SystemExit) as exc:
            load_config()

        assert str(path) in str(exc.value), section

    @pytest.mark.parametrize("key", ["max_age_seconds", "refresh_token"])
    def test_a_removed_key_says_so_rather_than_being_ignored(
        self, tmp_path, monkeypatch, key
    ):
        """`max_age_seconds` and `refresh_token` went with the cache."""
        path = write(
            tmp_path,
            f"[providers.serper]\nenabled = true\n\n[fetch]\n{key} = 1\n",
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))

        with pytest.raises(SystemExit) as exc:
            load_config()

        assert key in str(exc.value)

    def test_the_removed_knowledge_section_itself_is_rejected(
        self, tmp_path, monkeypatch
    ):
        """`[knowledge]` went with the fact store. A config still carrying it
        fails startup naming the section rather than the section being
        silently ignored."""
        path = write(
            tmp_path,
            "[providers.serper]\nenabled = true\n\n[knowledge]\nenabled = true\n",
        )
        monkeypatch.setenv("SEEKWRIGHT_CONFIG", str(path))

        with pytest.raises(SystemExit) as exc:
            load_config()

        assert "knowledge" in str(exc.value)


class TestTheDocumentedExample:
    """The config reference is executable, so it cannot drift unnoticed.

    Nothing else checks that `docs/reference/configuration.md` describes the
    config this code actually accepts. Before `Section` forbade unknown keys, a
    documented key that had been renamed or removed would have loaded silently
    and done nothing -- for every operator who copied the example.
    """

    DOC = Path(__file__).parent.parent / "docs" / "reference" / "configuration.md"

    @classmethod
    def source(cls) -> str:
        """The first TOML block in the configuration reference."""
        import re
        import tomllib

        blocks = re.findall(r"```toml\n(.*?)```", cls.DOC.read_text(), re.DOTALL)
        assert blocks, "the configuration reference has no TOML example"
        # Parse here too, so a malformed example fails as a parse error naming
        # the doc rather than as a confusing assertion downstream.
        tomllib.loads(blocks[0])
        return blocks[0]

    @classmethod
    def example(cls) -> dict[str, object]:
        import tomllib

        return tomllib.loads(cls.source())

    def test_it_loads_through_the_real_loader(self, tmp_path):
        """Written to a file and loaded, so the validators run as they would."""
        cfg = load_config(write(tmp_path, self.source()))

        assert cfg.enabled_providers()
        assert cfg.default_provider in cfg.enabled_providers()
        assert cfg.search.fallback == ["linkup", "exa:free"]

    def test_it_documents_every_section_the_model_has(self):
        """A new config section that nobody documented fails here."""
        documented = set(self.example())
        modelled = {
            name
            for name in Config.model_fields
            # `default_provider` is a scalar, documented as a comment above the
            # value rather than as a section.
            if name != "default_provider"
        }

        assert modelled <= documented, f"undocumented: {modelled - documented}"

    @classmethod
    def secrets_block(cls) -> str:
        """The fenced bash block under `## Secrets`: the copy-paste checklist."""
        import re

        block = re.search(
            r"^## Secrets\n+```bash\n(.*?)^```",
            cls.DOC.read_text(),
            re.DOTALL | re.MULTILINE,
        )
        assert block, "the configuration reference has no Secrets block"
        return block.group(1)

    def test_the_secrets_block_names_every_mandatory_key_provider(self):
        """Every provider that cannot start without a key is listed there.

        The block is what an operator pastes before first start, so a mandatory
        key missing from it is a startup `SystemExit` naming a variable the
        checklist never mentioned -- which is how `algolia` was missed. The
        TOML example above cannot catch it: the key never appears there.
        """
        import re

        named = {
            match[len("SEEKWRIGHT_") : -len("_API_KEY")].lower()
            for match in re.findall(
                # `0-9` is in the class on purpose: a backend segment need only be
                # a POSIX identifier.
                r"^export (SEEKWRIGHT_[A-Z0-9_]+_API_KEY)=",
                self.secrets_block(),
                re.MULTILINE,
            )
        }

        missing = PROVIDERS_REQUIRING_KEY - named
        assert not missing, f"the Secrets block omits: {sorted(missing)}"


class TestFetchFallbackShape:
    """The validator refuses a repeated fallback and a paid one that is not last.

    Both are refusals rather than the recommended list's side effect: a
    duplicated line or `scrappa` in the middle would have billed the paid
    fallback twice, or billed it before the free renderer was ever asked.
    """

    def test_the_recommended_shape_passes(self):
        FetchConfig(fallback=["crawl4ai", "scrappa"])

    def test_a_single_paid_fallback_passes(self):
        FetchConfig(fallback=["scrappa"])

    def test_a_single_free_fallback_passes(self):
        FetchConfig(fallback=["crawl4ai"])

    def test_a_duplicated_fallback_is_rejected(self):
        with pytest.raises(ValidationError, match="more than once"):
            FetchConfig(fallback=["scrappa", "scrappa"])

    def test_a_paid_fallback_that_is_not_last_is_rejected(self):
        with pytest.raises(ValidationError, match="last"):
            FetchConfig(fallback=["scrappa", "crawl4ai"])

    # `fetch.auto_fallback` says whether the ladder is walked, and nothing else: it
    # cannot reorder one or admit a second priced name (the tier rule "the
    # validator over the list is untouched").
    def test_the_walk_switch_cannot_move_the_tier_rule(self):
        with pytest.raises(ValidationError, match="can bill"):
            FetchConfig(fallback=["scrappa", "crawl4ai"], auto_fallback=True)

    def test_two_priced_fallbacks_are_refused_with_the_walk_on(self):
        with pytest.raises(ValidationError, match="can bill"):
            FetchConfig(fallback=["linkup", "scrappa"], auto_fallback=True)

    def test_the_walk_is_opt_in_by_default(self):
        """The key the walk moved behind, and the default that is the decision.

        Off, because a caller who cannot act on a failure should not be handed
        one: the read fails, or comes back with its page, and the sentence names
        the configured providers as something to choose.
        """
        assert FetchConfig().auto_fallback is False

    def test_an_unknown_fallback_is_refused_with_the_registry_printed(self):
        """The registry is what a deployment can now be told to choose from.

        The `Literal` this replaces printed nothing of the kind: the accepted names
        were the type, and widening it meant editing that type.
        """
        with pytest.raises(ValidationError) as exc:
            FetchConfig(fallback=["kagi"])

        message = str(exc.value)
        assert "fetch.fallback names unknown fallback(s) kagi" in message
        assert all(name in message for name in KNOWN_FALLBACKS), message

    # The two keyed fallbacks are provider names, and they bill, so both
    # halves of the tier rule apply to them with no clause written for either.
    def test_keyed_fallbacks_are_names_the_ladder_takes(self):
        assert FetchConfig(fallback=["crawl4ai", "jina", "tavily"]).fallback == [
            "crawl4ai",
            "jina",
            "tavily",
        ]
        assert FetchConfig(fallback=["jina", "linkup"]).fallback == ["jina", "linkup"]

    def test_a_keyed_paid_fallback_must_still_be_last(self):
        with pytest.raises(ValidationError, match="can bill"):
            FetchConfig(fallback=["linkup", "jina"])

    def test_two_keyed_paid_fallbacks_are_refused_as_well(self):
        """A ladder an operator would plausibly write, and the reason it cannot run.

        Three of the five registry rows can now bill, and two priced fallbacks cannot
        both be last: a page is priced by the fallback that served it, so a ladder with
        two of them would bill twice for one fetch.
        """
        with pytest.raises(ValidationError, match="can bill") as exc:
            FetchConfig(fallback=["scrappa", "tavily"])

        message = str(exc.value)
        assert "scrappa" in message and "tavily" in message

    @staticmethod
    def _second_billable_fallback(monkeypatch: pytest.MonkeyPatch) -> None:
        """A fallback this build has never heard of, which can bill, for one test only."""
        from seekwright import fetcher

        monkeypatch.setitem(
            fetcher.KNOWN_FALLBACKS,
            "pricedelsewhere",
            fetcher.Fallback(
                name="pricedelsewhere",
                billable=True,
                endpoint="https://priced-elsewhere.example/",
                build=lambda config: None,
            ),
        )

    @pytest.mark.parametrize(
        "ladder",
        [
            ["pricedelsewhere", "crawl4ai"],
            ["crawl4ai", "pricedelsewhere", "jina"],
            ["pricedelsewhere", "crawl4ai", "scrappa"],
        ],
    )
    def test_the_paid_last_rule_asks_the_tier_not_the_name(
        self, monkeypatch: pytest.MonkeyPatch, ladder: list[str]
    ):
        """The rule does not name `scrappa`, so any fallback that can bill falls under it.

        The third ladder is the one the free fallbacks cannot be reasoned about: one
        priced fallback sits last and the rule still refuses, because a ladder bills
        twice for one page either way.
        """
        self._second_billable_fallback(monkeypatch)

        with pytest.raises(ValidationError, match="can bill") as exc:
            FetchConfig(fallback=ladder)

        assert "pricedelsewhere" in str(exc.value)

    def test_a_billable_fallback_still_belongs_at_the_end(self, monkeypatch):
        """The rule is an ordering, not a ban: the new name is accepted where `scrappa` was."""
        self._second_billable_fallback(monkeypatch)

        ladder = FetchConfig(fallback=["crawl4ai", "pricedelsewhere"]).fallback

        assert ladder == ["crawl4ai", "pricedelsewhere"]


class TestFetchPrimaryShape:
    """`fetch.primary` names the route an unnamed fetch leads with, and only that.

    What the validator refuses is a name outside the fallback registry, never a
    tier: a billable primary is the operator paying a named price for every
    unnamed fetch, the same decision `search.default_provider` allows, and the
    ladder behind it still keeps the billable fallback last. So a priced primary
    must pass here even though the same name in the middle of a ladder is
    refused -- the two rules answer different questions.
    """

    def test_the_default_is_the_local_reader(self):
        """The state that reads from this server's own IP, which is the default."""
        assert FetchConfig().primary == "http"

    def test_the_local_reader_can_be_named_explicitly(self):
        assert FetchConfig(primary="http").primary == "http"

    @pytest.mark.parametrize("name", sorted(KNOWN_FALLBACKS))
    def test_every_registry_name_is_admissible_as_a_primary(self, name: str):
        """The registry, not a hand-written list, is what the key accepts -- and
        no name in it is refused for its tier."""
        assert FetchConfig(primary=name).primary == name

    def test_a_billable_primary_sits_behind_an_ordinary_ladder(self):
        """The tier rule governs the walk, not the route that leads it: `scrappa`
        is refused mid-ladder and accepted as the primary, with the same name
        still last in the ladder behind it."""
        cfg = FetchConfig(primary="scrappa", fallback=["crawl4ai", "scrappa"])

        assert cfg.primary == "scrappa"
        assert cfg.fallback == ["crawl4ai", "scrappa"]

    def test_an_unknown_route_is_refused_with_the_supported_names_printed(self):
        """A typo must not silently become the local reader: the message names
        every route this build knows, the local one included."""
        with pytest.raises(
            ValidationError, match="fetch.primary names unknown route"
        ) as exc:
            FetchConfig(primary="kagi")

        message = str(exc.value)
        assert "fetch.primary names unknown route 'kagi'" in message
        assert "http" in message
        assert all(name in message for name in KNOWN_FALLBACKS), message


class TestSearchSection:
    """`search.fallback` is the default route's ladder, and its shape is
    validated as startup policy rather than left to the serving path: unlike
    fetch's fallbacks, one that cannot run is a config error, because the whole
    point is serving through an outage."""

    def test_defaults_are_the_quiet_ones(self):
        cfg = Config(providers={"serper": ProviderConfig()})

        assert cfg.search.fallback is None
        assert cfg.search.health_interval_seconds == 60.0
        assert cfg.search.health_failure_threshold == 3
        assert cfg.search.health_cooldown_seconds == 120.0

    def test_a_valid_ladder_loads(self):
        cfg = Config(
            providers={
                "serper": ProviderConfig(),
                "linkup": ProviderConfig(),
            },
            default_provider="serper",
            search=SearchConfig(fallback=["linkup"]),
        )

        assert cfg.search.fallback == ["linkup"]

    def test_the_default_may_appear_in_the_ladder(self):
        """It is skipped as already tried at walk time, not a config error."""
        cfg = Config(
            providers={
                "serper": ProviderConfig(),
                "linkup": ProviderConfig(),
            },
            default_provider="serper",
            search=SearchConfig(fallback=["serper", "linkup"]),
        )

        assert cfg.search.fallback == ["serper", "linkup"]

    def test_a_duplicated_fallback_is_rejected(self):
        with pytest.raises(ValidationError, match="more than once"):
            SearchConfig(fallback=["linkup", "linkup"])

    def test_an_unknown_name_is_rejected(self):
        with pytest.raises(ValidationError, match="unknown provider"):
            SearchConfig(fallback=["kagi"])

    def test_a_known_but_disabled_name_is_rejected(self):
        """The fallback must be able to run: a disabled provider behind the
        default is ladder theatre, and fetch's inert-fallback allowance is
        deliberately not inherited here."""
        with pytest.raises(ValidationError, match="not an enabled provider"):
            Config(
                providers={"serper": ProviderConfig()},
                default_provider="serper",
                search=SearchConfig(fallback=["linkup"]),
            )

    def test_the_rejection_is_a_startup_error_through_the_loader(
        self, tmp_path, monkeypatch
    ):
        path = write(
            tmp_path,
            "[providers.serper]\nenabled = true\n\n"
            '[search]\nfallback = ["linkup"]\n',
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert "not an enabled provider" in str(exc.value)


class TestTheFreeSet:
    """The free set is a fact about the adapters, not about a pricing page.

    It is what `search(mode="free")` may dispatch to, so a name added here is
    a promise that the call cannot bill -- and a name left out is a claim that
    it can.
    """

    def test_it_is_the_five_that_cannot_bill(self):
        assert FREE_PROVIDERS == {
            "exa:free",
            "parallel:free",
            "freeserp",
            "searxng",
            "tinyfish",
        }

    def test_the_walk_puts_the_keyless_fallbacks_first(self):
        assert FREE_PROVIDER_ORDER == (
            "exa:free",
            "parallel:free",
            "freeserp",
            "searxng",
            "tinyfish",
        )

    def test_the_walk_is_a_permutation_of_the_set(self):
        """A name in the order but not the set would be dropped by the walk
        silently; the two are one fact and have to agree."""
        assert set(FREE_PROVIDER_ORDER) == FREE_PROVIDERS
        assert len(FREE_PROVIDER_ORDER) == len(set(FREE_PROVIDER_ORDER))

    def test_every_free_name_is_a_provider_the_package_implements(self):
        assert FREE_PROVIDERS <= KNOWN_PROVIDERS

    def test_the_metered_allowances_are_not_in_it(self):
        """Each has a free *tier*; none of them *cannot bill*."""
        assert FREE_PROVIDERS.isdisjoint({"scrappa", "tavily", "algolia"})
        # And the keyed-but-free-at-any-balance one is, deliberately.
        assert "tinyfish" in FREE_PROVIDERS
        assert "tinyfish" in PROVIDERS_REQUIRING_KEY


class TestSearch1ApiRouting:
    """`search1api` is keyed with a metered free tier, so it is billable.

    The 100 free credits are an *account* allowance, not an anonymous path:
    a search spends the operator's balance, and the key names whose. That is
    the same line that keeps `scrappa`, `tavily` and `algolia` out of the
    free set, so a `search1api` search is never a fallback `mode="free"` walks.
    It is enabled only by an explicit `[providers.search1api]` config, never
    by the implicit keyless set.
    """

    def test_it_is_known(self):
        assert "search1api" in KNOWN_PROVIDERS

    def test_it_requires_a_key(self):
        assert "search1api" in PROVIDERS_REQUIRING_KEY
        assert api_key_env_var("search1api") == "SEEKWRIGHT_SEARCH1API_API_KEY"

    def test_it_is_not_in_the_free_set(self):
        """A metered allowance is a price with a delay on it: it can bill."""
        assert "search1api" not in FREE_PROVIDERS

    def test_it_is_not_in_the_free_walk_order(self):
        assert "search1api" not in FREE_PROVIDER_ORDER

    def test_it_is_not_a_keyless_default(self):
        """An install that enables nothing never reaches search1api."""
        assert "search1api" not in KEYLESS_PROVIDERS
        cfg = Config()
        assert "search1api" not in cfg.providers

    def test_an_enabled_search1api_makes_the_default_route_billable(self):
        """One enabled name that can bill restores the refusal of a bare search."""
        cfg = Config(providers={"search1api": ProviderConfig()})
        assert cfg.enabled_providers() == ["search1api"]
        # With a single enabled provider the default resolves to it...
        assert cfg.default_provider == "search1api"
        # ...but the free set no longer covers the deployment, so an unnamed
        # search with no default would be refused, not walked.
        assert not cfg.default_route_is_free_only()

    def test_a_free_ladder_naming_search1api_is_rejected(self):
        with pytest.raises(ValidationError, match="can bill"):
            SearchConfig(free_fallback=["search1api"])

    def test_it_is_announced_as_untested(self):
        """The owner directive's visible status: implemented but untested."""
        assert "search1api" in UNTESTED_PROVIDERS
        assert UNTESTED_PROVIDERS <= KNOWN_PROVIDERS
        # And it never silently routes: the announced set is billable.
        assert UNTESTED_PROVIDERS.isdisjoint(FREE_PROVIDERS)
        assert UNTESTED_PROVIDERS.isdisjoint(KEYLESS_PROVIDERS)


class TestAnysearchRouting:
    """`anysearch` is keyless but explicit-only: a member of no walk.

    The 2026-10-16 SERP re-check passed AnySearch on the keyless route — no
    account, no key, no card, 1,000 requests a day — so a call through it
    cannot bill. It is nevertheless in none of the sets that route without
    the caller naming it: not the keyless install default, not the free set,
    not the free walk's order. The stance is the maintainer's, recorded in
    providers.md — a named provider, never an auto-routed or default one —
    and this class is what keeps a future "it's free, so put it in" from
    reversing it silently.
    """

    def test_it_is_known(self):
        assert "anysearch" in KNOWN_PROVIDERS

    def test_it_is_keyless(self):
        """No account exists to name, so no key guards it."""
        assert "anysearch" not in PROVIDERS_REQUIRING_KEY

    def test_it_is_not_in_the_free_set(self):
        """Explicit-only: being unable to bill does not admit it to the walk."""
        assert "anysearch" not in FREE_PROVIDERS

    def test_it_is_not_in_the_free_walk_order(self):
        assert "anysearch" not in FREE_PROVIDER_ORDER

    def test_it_is_not_a_keyless_default(self):
        """An install that enables nothing never reaches anysearch."""
        assert "anysearch" not in KEYLESS_PROVIDERS
        cfg = Config()
        assert "anysearch" not in cfg.providers

    def test_an_enabled_anysearch_is_reached_by_naming_not_walking(self):
        """The route to an enabled anysearch is the operator's explicit config.

        The free set still does not cover the deployment, so `mode="free"`
        and the unnamed-search free walk stay away from it: the stance keeps
        it out of the walks even though a call through it cannot bill.
        """
        cfg = Config(providers={"anysearch": ProviderConfig()})
        assert cfg.enabled_providers() == ["anysearch"]
        # With a single enabled provider the default resolves to it -- the
        # operator named it, and naming is exactly how it is reached...
        assert cfg.default_provider == "anysearch"
        # ...but the free set does not cover the deployment, so a free-mode
        # search has no fallback to walk.
        assert not cfg.default_route_is_free_only()

    def test_a_free_ladder_naming_anysearch_is_rejected(self):
        with pytest.raises(ValidationError, match="can bill"):
            SearchConfig(free_fallback=["anysearch"])

    def test_it_is_not_in_the_untested_set(self):
        """The live test has run (2026-10-17), so the name left the
        announced set: the startup line and `--check` no longer name it."""
        assert "anysearch" not in UNTESTED_PROVIDERS
        # The set's invariants still hold: a subset of the known names, and
        # disjoint from every walk a member of it must not take.
        assert UNTESTED_PROVIDERS <= KNOWN_PROVIDERS
        assert UNTESTED_PROVIDERS.isdisjoint(FREE_PROVIDERS)
        assert UNTESTED_PROVIDERS.isdisjoint(KEYLESS_PROVIDERS)


class TestSerpapiRouting:
    """`serpapi` is keyed with a metered free tier, so it is billable.

    The 250 searches/month are an *account* allowance, not an anonymous
    path: a search spends the operator's monthly quota, and the key names
    whose. That is the same line that keeps `scrappa`, `tavily` and
    `algolia` out of the free set, so a `serpapi` search is never a fallback
    `mode="free"` walks. It is enabled only by an explicit
    `[providers.serpapi]` config, never by the implicit keyless set -- and
    the name is distinct from `serper` (a different operator, endpoint and
    key), which the name scheme's guard over `KNOWN_PROVIDERS` keeps honest.
    """

    def test_it_is_known(self):
        assert "serpapi" in KNOWN_PROVIDERS

    def test_it_requires_a_key(self):
        assert "serpapi" in PROVIDERS_REQUIRING_KEY
        assert api_key_env_var("serpapi") == "SEEKWRIGHT_SERPAPI_API_KEY"

    def test_it_is_not_in_the_free_set(self):
        """A metered allowance is a price with a delay on it: it can bill."""
        assert "serpapi" not in FREE_PROVIDERS

    def test_it_is_not_in_the_free_walk_order(self):
        assert "serpapi" not in FREE_PROVIDER_ORDER

    def test_it_is_not_a_keyless_default(self):
        """An install that enables nothing never reaches serpapi."""
        assert "serpapi" not in KEYLESS_PROVIDERS
        cfg = Config()
        assert "serpapi" not in cfg.providers

    def test_an_enabled_serpapi_makes_the_default_route_billable(self):
        """One enabled name that can bill restores the refusal of a bare search."""
        cfg = Config(providers={"serpapi": ProviderConfig()})
        assert cfg.enabled_providers() == ["serpapi"]
        # With a single enabled provider the default resolves to it...
        assert cfg.default_provider == "serpapi"
        # ...but the free set no longer covers the deployment, so an unnamed
        # search with no default would be refused, not walked.
        assert not cfg.default_route_is_free_only()

    def test_a_free_ladder_naming_serpapi_is_rejected(self):
        with pytest.raises(ValidationError, match="can bill"):
            SearchConfig(free_fallback=["serpapi"])

    def test_it_is_announced_as_untested(self):
        """The owner directive's visible status: implemented but untested."""
        assert "serpapi" in UNTESTED_PROVIDERS
        # The announced set never intersects the routes it must not take.
        assert UNTESTED_PROVIDERS.isdisjoint(FREE_PROVIDERS)
        assert UNTESTED_PROVIDERS.isdisjoint(KEYLESS_PROVIDERS)


class TestQueritRouting:
    """`querit` is keyed with a metered free tier, so it is billable.

    The 1,000 free calls/month are an *account* allowance, not an anonymous
    path: a search spends the operator's monthly quota, and the key names
    whose. That is the same line that keeps `scrappa`, `tavily` and
    `algolia` out of the free set, so a `querit` search is never a fallback
    `mode="free"` walks. It is enabled only by an explicit
    `[providers.querit]` config, never by the implicit keyless set -- and the
    `/v1/contents` endpoint it shares the key with is a `fetch` concern, so
    the name is the search endpoint alone.
    """

    def test_it_is_known(self):
        assert "querit" in KNOWN_PROVIDERS

    def test_it_requires_a_key(self):
        assert "querit" in PROVIDERS_REQUIRING_KEY
        assert api_key_env_var("querit") == "SEEKWRIGHT_QUERIT_API_KEY"

    def test_it_is_not_in_the_free_set(self):
        """A metered allowance is a price with a delay on it: it can bill."""
        assert "querit" not in FREE_PROVIDERS

    def test_it_is_not_in_the_free_walk_order(self):
        assert "querit" not in FREE_PROVIDER_ORDER

    def test_it_is_not_a_keyless_default(self):
        """An install that enables nothing never reaches querit."""
        assert "querit" not in KEYLESS_PROVIDERS
        cfg = Config()
        assert "querit" not in cfg.providers

    def test_an_enabled_querit_makes_the_default_route_billable(self):
        """One enabled name that can bill restores the refusal of a bare search."""
        cfg = Config(providers={"querit": ProviderConfig()})
        assert cfg.enabled_providers() == ["querit"]
        # With a single enabled provider the default resolves to it...
        assert cfg.default_provider == "querit"
        # ...but the free set no longer covers the deployment, so an unnamed
        # search with no default would be refused, not walked.
        assert not cfg.default_route_is_free_only()

    def test_a_free_ladder_naming_querit_is_rejected(self):
        with pytest.raises(ValidationError, match="can bill"):
            SearchConfig(free_fallback=["querit"])

    def test_it_is_announced_as_untested(self):
        """The owner directive's visible status: implemented but untested."""
        assert "querit" in UNTESTED_PROVIDERS
        # The announced set never intersects the routes it must not take.
        assert UNTESTED_PROVIDERS.isdisjoint(FREE_PROVIDERS)
        assert UNTESTED_PROVIDERS.isdisjoint(KEYLESS_PROVIDERS)


class TestDeepseekRouting:
    """`deepseek` is keyed, and there is no free tier to be keyed *despite*.

    Search bills per successful request against a prepaid account balance, and
    ``402`` -- insufficient balance -- is the documented answer when that
    balance is gone. So the name sits out of every free route for the same
    reason `serper` and `linkup` do: it can always bill. It is enabled only by
    an explicit ``[providers.deepseek]`` config, and its bearer key is the same
    credential as the DeepSeek model API, so an operator who also points
    ``[agent]`` mode at DeepSeek spends one balance from two products.
    """

    def test_it_is_known(self):
        assert "deepseek" in KNOWN_PROVIDERS

    def test_it_requires_a_key(self):
        assert "deepseek" in PROVIDERS_REQUIRING_KEY
        assert api_key_env_var("deepseek") == "SEEKWRIGHT_DEEPSEEK_API_KEY"

    def test_it_is_not_in_the_free_set(self):
        """A prepaid balance is not an allowance: every search can bill."""
        assert "deepseek" not in FREE_PROVIDERS

    def test_it_is_not_in_the_free_walk_order(self):
        assert "deepseek" not in FREE_PROVIDER_ORDER

    def test_it_is_not_a_keyless_default(self):
        """An install that enables nothing never reaches deepseek."""
        assert "deepseek" not in KEYLESS_PROVIDERS
        cfg = Config()
        assert "deepseek" not in cfg.providers

    def test_an_enabled_deepseek_makes_the_default_route_billable(self):
        """One enabled name that can bill restores the refusal of a bare search."""
        cfg = Config(providers={"deepseek": ProviderConfig()})
        assert cfg.enabled_providers() == ["deepseek"]
        # With a single enabled provider the default resolves to it...
        assert cfg.default_provider == "deepseek"
        # ...but the free set no longer covers the deployment, so an unnamed
        # search with no default is refused, not walked.
        assert not cfg.default_route_is_free_only()

    def test_a_free_ladder_naming_deepseek_is_rejected(self):
        with pytest.raises(ValidationError, match="can bill"):
            SearchConfig(free_fallback=["deepseek"])

    def test_it_is_announced_as_untested(self):
        """The visible status: implemented against the docs, no live run yet."""
        assert "deepseek" in UNTESTED_PROVIDERS
        # The announced set never intersects the routes it must not take.
        assert UNTESTED_PROVIDERS.isdisjoint(FREE_PROVIDERS)
        assert UNTESTED_PROVIDERS.isdisjoint(KEYLESS_PROVIDERS)


class TestProviderNameScheme:
    """`backend` or `backend:flavour`, and the guard that stops the scheme rotting.

    A name is what an operator writes in a config table, in
    `SEEKWRIGHT_<BACKEND>_API_KEY` and on the `provider` parameter, so the halves
    of the scheme have to keep agreeing; the rules are in
    `docs/reference/provider-contract.md`. All three are asserted here: the
    bare-or-flavoured shape, the quoted-table form, and the env-var derivation.
    """

    def test_every_name_is_a_bare_key_or_a_known_backends_flavour(self):
        for name in sorted(KNOWN_PROVIDERS):
            backend, sep, flavour = name.partition(":")
            if not sep:
                # A bare name has to be a TOML key, because that is the form a
                # config table uses for it.
                parsed = tomllib.loads(f"[providers.{name}]\nenabled = true\n")
                assert name in parsed["providers"], name
                continue
            assert backend in KNOWN_PROVIDERS, (
                f"{name} qualifies {backend!r}, which is not a provider"
            )
            assert flavour, f"{name} carries an empty flavour"
            # Quoted, which is the only form that parses for a flavoured name.
            parsed = tomllib.loads(f'[providers."{name}"]\nenabled = true\n')
            assert name in parsed["providers"], name

    def test_no_name_derives_an_illegal_env_var(self, monkeypatch):
        """Every name's key has to be exportable, and it is `config.api_key`'s
        derivation that is asserted -- not a restatement of it."""
        providers = {
            name: ProviderConfig(
                url="http://searx.internal:8080" if name == "searxng" else None,
                app_id="APP" if name == "algolia" else None,
                index="idx" if name == "algolia" else None,
            )
            for name in sorted(KNOWN_PROVIDERS)
        }
        cfg = Config(providers=providers)
        legal = re.compile(r"[A-Z_][A-Z0-9_]*")

        for name in sorted(KNOWN_PROVIDERS):
            # The name taken whole is the illegal one whenever it is flavoured,
            # which is why the split exists at all.
            if ":" in name:
                assert not legal.fullmatch(f"SEEKWRIGHT_{name.upper()}_API_KEY")
            # Spelled out here rather than read back from the helper, so the
            # expectation is independent.
            var = f"SEEKWRIGHT_{name.split(':', 1)[0].upper()}_API_KEY"
            assert api_key_env_var(name) == var, f"{name} derives {var!r}"
            assert legal.fullmatch(var), f"{name} derives {var!r}"
            monkeypatch.setenv(var, "k")
            assert cfg.api_key(name) == "k", f"{name} reads the wrong variable"
            monkeypatch.delenv(var)


class TestSearchFreeFallback:
    """`search.free_fallback` is the free-only mode's ladder. It takes
    `search.fallback`'s shape and adds the rule that makes the mode honest: no
    fallback that can bill. The mode's promise is a ceiling of zero, so a paid name
    is a startup error rather than a fallback the walk quietly declines to take."""

    def test_it_is_unset_by_default(self):
        cfg = Config(providers={"serper": ProviderConfig()})
        assert cfg.search.free_fallback is None

    def test_a_valid_free_ladder_loads(self):
        cfg = Config(
            providers={
                "exa:free": ProviderConfig(),
                "parallel:free": ProviderConfig(),
            },
            search=SearchConfig(free_fallback=["parallel:free", "exa:free"]),
        )

        assert cfg.search.free_fallback == ["parallel:free", "exa:free"]

    @pytest.mark.parametrize("name", ["scrappa", "tavily", "algolia"])
    def test_a_provider_that_can_bill_is_rejected_naming_it(self, name):
        """A free tier is an allowance that runs out -- a price with a delay
        on it -- so these three are not in the free set."""
        with pytest.raises(ValidationError) as exc:
            SearchConfig(free_fallback=[name])

        assert "can bill" in str(exc.value)
        assert name in str(exc.value)

    def test_a_duplicated_fallback_is_rejected(self):
        with pytest.raises(ValidationError, match="more than once"):
            SearchConfig(free_fallback=["exa:free", "exa:free"])

    def test_an_unknown_name_is_rejected(self):
        with pytest.raises(ValidationError, match="unknown provider"):
            SearchConfig(free_fallback=["kagi"])

    def test_a_known_but_disabled_name_is_rejected(self):
        with pytest.raises(ValidationError, match="not an enabled provider"):
            Config(
                providers={
                    "serper": ProviderConfig(),
                    "exa:free": ProviderConfig(enabled=False),
                },
                search=SearchConfig(free_fallback=["exa:free"]),
            )

    def test_the_rejection_is_a_startup_error_through_the_loader(self, tmp_path):
        path = write(
            tmp_path,
            "[providers.serper]\nenabled = true\n\n"
            '[search]\nfree_fallback = ["tavily"]\n',
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert "tavily" in str(exc.value)
        assert "can bill" in str(exc.value)


class TestAgentConfig:
    """Agent mode's section: off by default, and incomplete-on is reportable.

    The three missing pieces are *reported* rather than raised, because two
    callers need the same fact at different temperatures: `server.main` refuses
    to start on it, `--check` prints it and exits 1. Both read
    ``missing_agent_settings``, so they cannot disagree about what "configured"
    means.
    """

    def test_the_default_is_off(self):
        cfg = AgentConfig()

        assert cfg.enabled is False
        assert (cfg.base_url, cfg.model) == (None, None)
        assert cfg.timeout_seconds == 90.0
        assert cfg.model_timeout_seconds == 30.0
        assert cfg.max_material_chars == 24000
        assert (cfg.max_output_tokens_brief, cfg.max_output_tokens_report) == (500, 2500)
        assert cfg.max_cost_usd == 0.25
        assert (cfg.cost_per_1k_in, cfg.cost_per_1k_out) == (None, None)

    def test_a_config_without_the_section_still_gets_one(self):
        cfg = Config(providers={"serper": ProviderConfig()})

        assert cfg.agent.enabled is False
        assert cfg.missing_agent_settings() == []

    def test_an_unknown_key_in_the_section_is_a_startup_error(self, tmp_path):
        path = write(
            tmp_path,
            "[providers.serper]\nenabled = true\n\n[agent]\nmodell = \"x\"\n",
        )

        with pytest.raises(SystemExit) as exc:
            load_config(path)

        assert str(path) in str(exc.value)

    def test_disabled_needs_nothing(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_AGENT_API_KEY", raising=False)

        assert AgentConfig().enabled is False
        assert (
            Config(
                providers={"serper": ProviderConfig()}, agent=AgentConfig()
            ).missing_agent_settings()
            == []
        )

    def test_an_enabled_section_missing_everything_names_all_three(self, monkeypatch):
        monkeypatch.delenv("SEEKWRIGHT_AGENT_API_KEY", raising=False)
        cfg = Config(
            providers={"serper": ProviderConfig()},
            agent=AgentConfig(enabled=True),
        )

        assert cfg.missing_agent_settings() == [
            "agent.base_url",
            "agent.model",
            "SEEKWRIGHT_AGENT_API_KEY",
        ]

    def test_the_key_comes_from_the_environment_only(self, tmp_path, monkeypatch):
        """Never the config file -- files get committed, like every provider key."""
        monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "sk-from-env")
        path = write(
            tmp_path,
            "[providers.serper]\nenabled = true\n\n"
            "[agent]\nenabled = true\n"
            'base_url = "https://model.test/v1"\nmodel = "m"\n',
        )
        cfg = load_config(path)

        assert cfg.missing_agent_settings() == []
        assert cfg.agent_api_key() == "sk-from-env"

    def test_a_complete_section_reports_nothing_missing(self, monkeypatch):
        monkeypatch.setenv("SEEKWRIGHT_AGENT_API_KEY", "sk")
        cfg = Config(
            providers={"serper": ProviderConfig()},
            agent=AgentConfig(
                enabled=True, base_url="https://model.test/v1", model="m"
            ),
        )

        assert cfg.missing_agent_settings() == []

class TestTheDocumentedRoles:
    """The two role configs the deploy runbook ships are loadable, and each
    one holds the role it names.

    The default deployment is two containers built from one image, and the only
    thing that makes them different is the config file each mounts: the search
    role closes `fetch`, the fetch role closes every provider dispatch. A key
    renamed, or a top-level key written below a table header, turns one of those
    blocks into a startup error for every operator who pasted it -- the same
    failure `TestTheDocumentedExample` guards for the main example, read here
    against the page that carries the split.
    """

    DOC = Path(__file__).parent.parent / "docs" / "reference" / "deploying.md"

    @classmethod
    def role(cls, heading: str) -> str:
        """The one TOML block under a role heading of the runbook."""
        block = re.search(
            rf"^### {heading}.*?```toml\n(.*?)```",
            cls.DOC.read_text(encoding="utf-8"),
            re.DOTALL | re.MULTILINE,
        )
        assert block, f"{cls.DOC.name}: no TOML example under the {heading!r} heading"
        tomllib.loads(block.group(1))
        return block.group(1)

    def test_the_search_role_cannot_fetch(self, tmp_path):
        """Its `fetch` is off, and every name it permits is a name it enables."""
        cfg = load_config(write(tmp_path, self.role("The search role")))

        assert cfg.fetch.enabled is False
        assert cfg.enabled_providers()
        assert cfg.permitted_providers is not None
        assert set(cfg.permitted_providers) <= set(cfg.enabled_providers())

    def test_the_fetch_role_cannot_dispatch_a_provider(self, tmp_path):
        """Its permission set is declared empty, so no search reaches an adapter.

        The empty set is not the unset one: unset is permissive, and an unset
        key here would leave the keyless trio reachable, which is the difference
        the runbook is built on.
        """
        cfg = load_config(write(tmp_path, self.role("The fetch role")))

        assert cfg.fetch.enabled is True
        assert cfg.permitted_providers == []
        assert not cfg.missing_api_keys()

