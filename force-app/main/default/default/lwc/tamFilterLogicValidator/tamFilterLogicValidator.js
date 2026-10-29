export default class TamFilterLogicValidator {

    static validate(logicString, filterIds) {
        // No logic => valid; caller can decide if it's required
        if (!logicString || logicString.trim() === '') {
            return { valid: true };
        }

        // Normalize spaces and case
        let s = logicString.replace(/\s+/g, ' ').trim();
        const upper = s.toUpperCase();

        // 1) ALLOWED CHARACTERS: digits, parentheses, whitespace, AND, OR
        const stripped = upper.replace(/AND|OR/g, '');
        const allowedRegex = /^[0-9()\s]+$/;
        if (!allowedRegex.test(stripped)) {
            return { valid: false, message: 'Invalid characters in filter logic.' };
        }

        // 2) PARENTHESES BALANCE
        if (!this.checkParentheses(upper)) {
            return { valid: false, message: 'Parentheses are not balanced.' };
        }

        // 3) AND/OR GROUPING RULE
        // If AND and OR are mixed in the same group (top-level or any (...) group), it's invalid.
        const groupCheck = this.checkAndOrGrouping(upper);
        if (!groupCheck.valid) {
            return groupCheck;
        }

        // 4) TOKENIZE (simple, by spaces)
        const tokens = upper.split(' ').filter(t => t.length > 0);

        // 5) BASIC SYNTAX + FILTER EXISTENCE CHECK
        const syntax = this.validateSyntax(tokens, filterIds);
        if (!syntax.valid) {
            return syntax;
        }

        return { valid: true };
    }

    // ===== Helpers =====

    // Check parentheses balance
    static checkParentheses(s) {
        let stack = 0;
        for (let ch of s) {
            if (ch === '(') stack++;
            if (ch === ')') stack--;
            if (stack < 0) return false;
        }
        return stack === 0;
    }

    /**
     * Enforce:
     * - It's illegal to mix AND and OR at the same "group" level.
     * - Groups:
     *   - Top level (outside any parentheses)
     *   - Each (...) pair
     *
     * Valid examples:
     *   1 AND 2
     *   1 OR 2
     *   1 AND (2 OR 3)
     *   (1 AND 2) OR 3
     *
     * Invalid:
     *   1 AND 2 OR 3
     *   (1 AND 2 OR 3)
     */
    static checkAndOrGrouping(s) {
        const topOps = new Set();
        const stack = []; // stack of Sets, one per (...) group

        // Helper to add op to the current group
        const addOp = (op) => {
            if (stack.length > 0) {
                stack[stack.length - 1].add(op);
            } else {
                topOps.add(op);
            }
        };

        // Scan through string: track depth via '(' and ')', detect AND/OR as words
        for (let i = 0; i < s.length; i++) {
            const ch = s[i];

            if (ch === '(') {
                // new group
                stack.push(new Set());
                continue;
            }

            if (ch === ')') {
                // closing a group: check its operators
                const ops = stack.pop();
                if (ops && ops.has('AND') && ops.has('OR')) {
                    return {
                        valid: false,
                        message: 'When using both AND and OR, use parentheses to group conditions clearly (e.g. 1 AND (2 OR 3) or (1 AND 2) OR 3).'
                    };
                }
                continue;
            }

            // detect AND
            if (s.startsWith('AND', i)) {
                const before = i === 0 ? ' ' : s[i - 1];
                const after = i + 3 >= s.length ? ' ' : s[i + 3];
                if (/[\s(]/.test(before) && /[\s)]/.test(after)) {
                    addOp('AND');
                    i += 2; // skip ND
                    continue;
                }
            }

            // detect OR
            if (s.startsWith('OR', i)) {
                const before = i === 0 ? ' ' : s[i - 1];
                const after = i + 2 >= s.length ? ' ' : s[i + 2];
                if (/[\s(]/.test(before) && /[\s)]/.test(after)) {
                    addOp('OR');
                    i += 1; // skip R
                    continue;
                }
            }
        }

        // After processing all parentheses, check top-level operators
        if (topOps.has('AND') && topOps.has('OR')) {
            return {
                valid: false,
                message: 'When using both AND and OR, use parentheses to group conditions clearly (e.g. 1 AND (2 OR 3) or (1 AND 2) OR 3).'
            };
        }

        return { valid: true };
    }

    // Validate token-to-token structure
    static validateSyntax(tokens, filterIds) {
        const operators = ['AND', 'OR'];

        for (let i = 0; i < tokens.length; i++) {
            const current = tokens[i];
            const prev = tokens[i - 1];
            const next = tokens[i + 1];

            // CASE 1: numeric references
            if (/^\d+$/.test(current)) {
                const id = Number(current);
                // filterIds MUST be an array of numbers
                if (!filterIds.includes(id)) {
                    return { valid: false, message: `Filter ${id} does not exist.` };
                }
                // Must not be directly followed by another number
                if (next && /^\d+$/.test(next)) {
                    return { valid: false, message: `Invalid sequence: ${current} ${next}` };
                }
            }

            // CASE 2: operators
            if (operators.includes(current)) {
                if (!prev || !next) {
                    return { valid: false, message: 'Operator cannot be at start or end.' };
                }
                if (operators.includes(prev) || operators.includes(next)) {
                    return { valid: false, message: 'Two operators cannot be adjacent.' };
                }
                if (next === ')') {
                    return { valid: false, message: 'Operator cannot be followed by closing parenthesis.' };
                }
            }

            // CASE 3: parentheses *tokens* – these only work if user put spaces, but we keep them
            if (current === '(') {
                if (next && operators.includes(next)) {
                    return { valid: false, message: 'Operator cannot follow opening parenthesis.' };
                }
            }

            if (current === ')') {
                if (prev && operators.includes(prev)) {
                    return { valid: false, message: 'Operator cannot end before closing parenthesis.' };
                }
            }
        }

        return { valid: true };
    }
}