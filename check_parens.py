
def check_parens(filename):
    with open(filename, 'r') as f:
        lines = f.readlines()

    stack = []
    for i, line in enumerate(lines):
        for j, char in enumerate(line):
            if char == ';':  # Comment
                break
            if char == '(':
                stack.append((i + 1, j + 1))
            elif char == ')':
                if not stack:
                    print(f"Excess closing parenthesis at line {i+1}, col {j+1}")
                    return
                stack.pop()
    
    if stack:
        print(f"Unclosed parentheses: {len(stack)}")
        for item in stack[-1:]: #-min(3, len(stack)):]:
            print(f"  Line {item[0]}, col {item[1]}")
    else:
        print("Parentheses balanced.")

print("Checking noteworthy-evil.el:")
check_parens("noteworthy-evil.el")
print("\nChecking noteworthy-collab.el:")
check_parens("noteworthy-collab.el")
