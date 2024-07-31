import re
from pathlib import Path
from typing import Annotated
from dataclasses import dataclass, field

# The following regex pattern captures the Firefox user_pref settings from the user.js file.
# Details -> https://regexr.com/845i3

PATTERN = r'\/\/ (?P<description>.*)\n\/\/ default: (?P<default_value>.*)\nuser_pref\("(?P<key>.*)"\, (?P<value>.*)\);'
COMPILED_PATTERN = re.compile(PATTERN)

# If you have a problem and use regular expressions, you now have two problems!
# I have many problems.

@dataclass
class Setting:
    key: str = field(metadata="Preference Name")
    value: str = field(metadata="Updated value")
    description: str = field(metadata="Description")
    default_value: str = field(metadata="Default value")
    
    @classmethod
    def ordered_values(cls: 'Setting') -> tuple[str]:
        field = lambda x: cls.__dataclass_fields__[x]
        return (field("key"), field("description"), field("value"), field("default_value"))

    @classmethod
    def as_markdown_table_header(cls: 'Setting') -> str:
        format = lambda x: f"**{x}**"
        columns = [format(field.metadata) for field in cls.ordered_values()]
        md_header = "| " + " | ".join(columns) + " |"
        md_divider = "|" + "-|" * len(columns)
        return md_header + "\n" + md_divider
    
    def as_markdown_table_row(self) -> str:
        attr = lambda x: getattr(self, x.name)
        format = lambda x: x if x == self.description else f"`{x}`"

        columns = [format(attr(field)) for field in self.ordered_values()]
        return "| " + " | ".join(columns) + " |"
    
@dataclass
class Settings:
    userjs: Path
    regex_pattern: re.Pattern
    
    @property
    def values(self) -> list[Setting]:
        file_data = self.userjs.read_text()
        matches = re.finditer(self.regex_pattern, file_data)
        return [Setting(**match.groupdict()) for match in matches]
    
    def as_markdown_table(self) -> str:
        header = Setting.as_markdown_table_header()
        rows = [setting.as_markdown_table_row() for setting in self.values]
        return f"{header}\n" + "\n".join(rows)

@dataclass
class Readme:
    readme_path: Path

    start_marker: str = "<!-- START_PREF_TABLE -->"
    end_marker: str = "<!-- END_PREF_TABLE -->"

    def update(self, settings: Settings) -> None:
        with open(self.readme_path, 'r', encoding='utf-8') as f:
            readme_content = f.read()

        new_table = settings.as_markdown_table()

        placeholder_pattern = rf"{re.escape(self.start_marker)}([\s\S]*?){re.escape(self.end_marker)}"
        updated_readme = re.sub(placeholder_pattern, f"{self.start_marker}\n{new_table}\n{self.end_marker}", readme_content)

        with open(self.readme_path, 'w', encoding='utf-8') as f:
            f.write(updated_readme)

if __name__ == "__main__":
    userjs_path = Path("dotfiles/firefox/profile/user.js")
    readme_path = Path("dotfiles/firefox/README.md")

    settings = Settings(userjs=userjs_path, regex_pattern=COMPILED_PATTERN)
    readme = Readme(readme_path=readme_path)

    readme.update(settings)