clc
clear
% uses CasADi v3.5.1
% www.casadi.org
import casadi.*

% Written by: Dinesh Krishnamoorthy, Nov 2021
%%
global nx nu nd
global lbx ubx dx0 lbu ubu u0
nx =2; nu = 1; nd = 2;
lbu = -200*ones(nu,1); ubu = 200*ones(nu,1); u0  = 0;
lbx = [0,-5]'; ubx = [2*pi,5]'; dx0 = [0;0];

par.tf = 0.5;
[sys,par] = pendulum(par);

d_val = [2;pi];

par.N = 30; % Length to prediction horizon
par.ROC = 0;
[solver,par] = buildNLP(sys.f,par);
n_w_i = nx + par.N*(4*nx+nu);


par.nIter = 40; % lenght of each rollout

K = [-11,-7,35]; % initial linear policy

par.nAug = 5;
nr = 0; % counter to collect augmented data
nr2 = 0;% counter to collect expert data

AugmentedFeedback = 0; % select whether to use data augmentation

for rollout = 1:15
    disp(['Rollout: ' num2str(rollout)])
    
    xf = [0;0]; % start from pendulum at rest at each rollout
    
    for run = 1:2
        if run == 1 % Current Policy Rollout
            for t = 1:par.nIter
                if rollout == 1
                    NMPC.u(t) = K(1:2)*xf + K(3); % initial linear policy
                else
                    NMPC.u(t) = sim(Approx_policy,xf);
                end
                NMPC.x(:,t) = xf;
                %------------------------ Plant simulation----------------------
                u_in = NMPC.u(t);
                Fk = sys.F('x0',xf,'p',vertcat(u_in,d_val));
                xf =  full(Fk.xf) ;
            end
        end
        Policy(rollout) = NMPC;
        
        % ===================================================================
        
        if run == 2 % Get expert feedback
            
            for t = 1:par.nIter
                tic;
                sol = solver('x0',par.w0,'p',vertcat(NMPC.x(:,t),0,d_val),...
                    'lbx',par.lbw,'ubx',par.ubw,...
                    'lbg',par.lbg,'ubg',par.ubg);
                elapsednlp = toc;
                
                flag = solver.stats();
                if ~flag.success
                    warning(['Expert says: ' flag.return_status])
                else
                    Primal = full(sol.x);
                    Dual.lam_g = full(sol.lam_g);
                    Dual.lam_x = full(sol.lam_x);
                    Dual.lam_p = full(sol.lam_p);
                    
                    u1_opt = [Primal(nx+1:4*nx+nu:n_w_i);NaN];
                    x1_opt = Primal([1,nu+4*nx+1:4*nx+nu:n_w_i]);
                    x2_opt = Primal([2,nu+4*nx+2:4*nx+nu:n_w_i]);
                    nr2 = nr2+1;
                    Expert.x(:,nr2) = NMPC.x(:,t);
                    Expert.u(nr2) = Primal(nx+1);
                    Expert.sol_t(nr2) = elapsednlp;
                end
                x_i = NMPC.x(:,t);
                u_i = 0;
                d_i = d_val;
                
                if flag.success % Augment data using expert feedback
                    
                    % ------- Data Augmentation -------
                    
                    fr = 2*pi*rand(par.nAug*par.nAug,1);
                    r = 0.6*sqrt(rand(par.nAug*par.nAug,1));
                    x1 = x_i(1) + r.*cos(fr);
                    x2 = x_i(2) + r.*sin(fr);
                    
                    xip = [x1,x2]';
                    
                    for j = 1:par.nAug*par.nAug
                        % ----------- Tangential PRedictor ------------
                        nr = nr+1;
                        AugData.u(:,nr) = Expert.u(nr2);
                        AugData.x(:,nr) = Expert.x(:,nr2);
                        AugData.sol_t(nr) = Expert.sol_t(nr2);
                        nr = nr+1;
                        if j == 1
                            [solLS,elapsed,H] = SolveLinSysOnline(Primal,Dual,vertcat(x_i,u_i,d_i),vertcat(xip(:,j),u_i,d_i),par);
                            nw = numel(Primal);
                            ng = numel(Dual.lam_g);
                        else
                            dp = (vertcat(xip(:,j),u_i,d_i)-vertcat(x_i,u_i,d_i));
                            tic
                            Delta_s = H*dp;
                            elapsed = toc;
                            
                            solLS.dx = Delta_s(1:nw);
                            solLS.lam_g = Delta_s(nw+1:nw+ng);
                            solLS.lam_x = Delta_s(nw+ng+1:nw+ng+1);
                        end
                        w_opt_p = Primal + full(solLS.dx);
                        lam_g_p = Dual.lam_g + full(solLS.lam_g);
                        lam_x_p = Dual.lam_x + full(solLS.lam_x);
                        
                        u1_opt_p = [w_opt_p(nx+1:4*nx+nu:n_w_i);NaN];
                        x1_opt_p = w_opt_p([1,nu+4*nx+1:4*nx+nu:n_w_i]);
                        x2_opt_p = w_opt_p([2,nu+4*nx+2:4*nx+nu:n_w_i]);
                        
                        AugData.u(:,nr) = u1_opt_p(1);
                        AugData.x(:,nr) = vertcat(x1_opt_p(1),x2_opt_p(1));
                        AugData.sol_t(nr) = elapsed;
                        
                    end
                end
            end
        end
    end
    
    %% Update Policy
    
    if AugmentedFeedback
        % use expert + augmened data to update policy
        Approx_policy = newgrnn(AugData.x,AugData.u,0.2);
    else
        % use only expert feedback to update policy
        Approx_policy = newgrnn(Expert.x,Expert.u,0.2);
    end
    
    %%
    figure(12)
    clf
    hold all
    plot3(Expert.x(1,:),Expert.x(2,:),Expert.u,'ro','linewidth',1.5)
    if AugmentedFeedback
        plot3(AugData.x(1,:),AugData.x(2,:),AugData.u,'k.')
    end
    hold all
    xlim([0,7])
    ylim([-5,5])
    grid on
    box on
    xlabel(' $ \omega$','Interpreter','latex')
    ylabel(' $ \dot\omega$','Interpreter','latex')
    zlabel(' $ \pi(x)$','Interpreter','latex')
    legend('Expert feedback','Augmented feedback',...
        'Interpreter','latex')
    axs = gca;
    axs.FontSize = 14;
    axs.TickLabelInterpreter = 'latex';
end

%% Plot the performance using the latest policy after 10 rollouts

figure(21)
hold all
plot(Policy(rollout).x(1,:),Policy(rollout).x(2,:))

figure(22)
hold all
plot([1:40]./2,Policy(rollout).x(1,:))
grid on
box on
ylabel(' $ \omega$','Interpreter','latex')
xlabel(' Time [s]','Interpreter','latex')
axs = gca;
axs.FontSize = 14;
axs.TickLabelInterpreter = 'latex';
