import re
from pathlib import Path
from itertools import product

# Ajuste se quiser mais agressivo
LEET = {
    "a": ["a", "@", "4"],
    "e": ["e", "3"],
    "i": ["i", "1", "!"],
    "o": ["o", "0"],
    "s": ["s", "$", "5"],
    "t": ["t", "7"],
    "g": ["g", "9"],
    "c": ["c", "("],
    "u": ["u", "v"],
}

SEPARATORS = ["", " ", ".", "_", "-", "*"]  # variações com símbolos
MAX_VARIANTS_PER_WORD = 5000  # evita explosão combinatória; aumente com cuidado

def extract_strings(lua_text: str):
    # extrai "...." (strings Lua simples)
    return re.findall(r'"([^"]*)"', lua_text)

def variants_for_word(w: str):
    w = w.strip().lower()
    if not w:
        return set()

    # Se tiver espaços, também gera versão compacta
    bases = {w, w.replace(" ", "")}

    out = set()
    for base in bases:
        # monta opções por caractere (leet quando aplicável)
        char_opts = []
        for ch in base:
            if ch.isalnum():
                opts = LEET.get(ch, [ch])
                char_opts.append(opts)
            else:
                # mantém símbolos/acento literal como opção única
                char_opts.append([ch])

        # gera combinações de leet (limitando crescimento)
        # (se ficar grande, reduz automaticamente)
        combos = 1
        for opts in char_opts:
            combos *= len(opts)
            if combos > 20000:
                # reduz leet: pega só a forma original para conter explosão
                char_opts = [[opts[0]] for opts in char_opts]
                break

        leet_forms = []
        for tup in product(*char_opts):
            leet_forms.append("".join(tup))
            if len(leet_forms) > 2000:
                break

        # aplica separadores entre caracteres
        for lf in leet_forms:
            chars = list(lf)
            # junta com separadores (amostra controlada para não explodir)
            # estratégia: gera algumas opções por separador, não o produto completo
            joined = set()

            # padrão: mesmo separador em toda a palavra
            for sep in SEPARATORS:
                joined.add(sep.join(chars))

            # padrão: mistura leve (alternando), limitado
            if len(chars) <= 32:
                joined.add(" ".join(chars))
                joined.add(".".join(chars))
                joined.add("_".join(chars))
                joined.add("-".join(chars))

            out.update(joined)
            if len(out) >= MAX_VARIANTS_PER_WORD:
                break

    return out

def to_lua_return(items):
    lines = ["return {"]
    for s in sorted(items):
        s2 = s.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    "{s2}",')
    lines.append("}")
    return "\n".join(lines)

def main():
    in_path = Path("chat_filter_blacklist.lua")        # Input file
    out_path = Path("chat_filter_blacklist_expanded.lua")  # Output file

    if not in_path.exists():
        print(f"Error: {in_path} not found.")
        return

    base_text = in_path.read_text(encoding="utf-8", errors="replace")
    base_words = extract_strings(base_text)

    expanded = set()
    for w in base_words:
        expanded.add(w.strip().lower())
        expanded.update(variants_for_word(w))

    out_path.write_text(to_lua_return(expanded), encoding="utf-8")
    print(f"OK: {len(base_words)} termos base -> {len(expanded)} termos expandidos em {out_path}")

if __name__ == "__main__":
    main()
