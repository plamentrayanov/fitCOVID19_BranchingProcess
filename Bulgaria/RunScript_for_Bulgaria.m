%% Modelling COVID-19 with a General Branching Process (GBP), also called Crump-Mode-Jagers branching process
% load the paths to the branching process simulator and the data.csv
addpath('../lib/')       % adds the function BranchingProcessSimulator to the path
addpath('../')          % adds the functions confInterval and readCSVData to the path

% read the data from data.csv for the chosen country
% the data is taken from: https://opendata.ecdc.europa.eu/covid19/casedistribution/csv
[dates, newcases_hist, totalcases_hist] = readWorldometerData('Bulgaria');

%% Specify general parameters for the simulations and the model
sim_num = 1000;     % number of simulations to perform
horizon = 90;       % horizon in days, after the last available data
save_plots = true;      % save the plots generated by the script
conf_lvl_plots = 0.95;  % 95% confidence intervals are drawn for the simulations

detection_time = 8;     % assumes 2 days after the symptoms develop (on average) the person is tested for corona
num_days_passed = dates(end)-dates(1) + 1 + detection_time;   % days passed since the infection began = days since first case + detection time needed
T = num_days_passed+horizon;          % the simulation period for the process, from the first infected to horizon 
h = 0.5;          % the time step is 0.5 day
omega = 60;           % no one is infected for more than omega days, technical parameter that does not need to be accurate, smaller -> faster speed, 
                    % but it needs to be large enough so the P(staying infected after omega days) is very close to zero.

%% model specification for S, survivability function, NOT to be mistaken with the percentage of people who survive the virus!
% S is virus specific and represents the survivability function of the virus inside the body of a person
% Here it is assumed normally distributed where the values mu and sigma are taken from the article:
% "Feasability of controlling 2019-nCoV outbreaks by isolation of cases and contacts", J. Hellewell, S. Abbot, et al. 
% https://doi.org/10.1101/2020.02.08.20021162
%
% average time for recovery in the article is 5.8 + 9.1 = 14.9, std = sqrt(2.6^2 + 19.53) = 5.1274
% however the data in bulgaria (recovery rates and active cases) seems to show that people need more time to clear the virus out of their body
% even after they are already healthy and recovered. As worldometers.info writes, the active cases and recoveries depend highly on the way we count a recovery.
% In Bulgaria it is counted after a person tests negative twice for the virus. It seems that average infection lifelength of 35 gives the best
% approximation for the active cases in Bulgaria.
% The mean and sigma for S here should be such that the person does not carry any infection at all after that period! This however
S=(1-normcdf(0:h:omega, 35, 5.1274)')./(1-normcdf(0, 35, 5.1274));    % trimmed normal life length
S(end)=0;           % staying infected for more than omega days is with probability zero

U=1;    % no types - no mutations, there is a possibility to include a second, quarantined type here with a probability to become quarantined

H=[0, 1]';      % people infect only 1 other person when infection happens, no multiple infections

% the initial number of infections is taken to be the first daily cases count. For simplicity, only a trivial age distribution for Z_0 is assumed.
Z_0=[newcases_hist(1); zeros(omega/h, 1)];

%% mu model, specific for the virus (not yet scaled by R0)
% values are taken from the article https://doi.org/10.1101/2020.02.08.20021162
% from onset to isolation 3.83 (var = 5.99)
% incubation 5.8 (std = 2.6)
% average time of infecting other people is 5.8 + 3.83 = 9.63, std = sqrt(2.6^2 + 5.99) = 3.5707
% Expectation = k * theta = 9.63, Variance = k * theta^2 = 3.5707^2 => theta = 3.5707^2 / 9.63 = 1.3240, k = 9.63/1.3240 = 7.2734

mu_covid_pdf=gampdf(0:h:omega, 7.2734, 1.3240)';

%% IMMIGRATION MODEL
% immigration age distribution model (not yet scaled by immigration count at this point)
% a little bit of immigration is allowed in the model
Im_mu_daily_max = Inf;   % the maximum allowed daily immigration (must be dividible by h)
Im_mu_max = Im_mu_daily_max*h;   % the maximum allowed immigration for a period h

Im_age_struct_pdf=unifpdf(0:h:omega, 0, 8)';
Im_age_struct_prob=Im_age_struct_pdf./(sum(Im_age_struct_pdf));

%% ESTIMATION OF R0 AND IMMIGRATION
% we start from some initial values and find the implied values for 
R0_daily_start = linspace(2.5, 2.5, length(totalcases_hist));
Im_mu_daily_start = linspace(5, 5, length(totalcases_hist));

optim_options=optimoptions('fmincon', 'Algorithm', 'active-set', 'Display', 'iter-detailed', 'UseParallel', true, 'MaxIterations', 500, ...
    'MaxFunctionEvaluations', 1e7, 'FunctionTolerance', 1e-4, 'OptimalityTolerance', 1e-7);

% we look for R0 between 0.3 and 5, that changes smoothly over time, we look for immigration probabilities that change smoothly over time
% immigration is defined here as number of people who arrive from abroad sick AND start infecting other people
LB=[0.1*ones(size(R0_daily_start,2),1); zeros(size(R0_daily_start,2),1)];
UB=[10*ones(size(R0_daily_start,2),1); Im_mu_max*ones(size(R0_daily_start,2),1)];

% smoothing parameters:
lmb_newcases = 1;     % penalty for non-smoothness in the projected new cases from the model
lmb_R0 = 0.5;          % penalty for non-smoothness in R0(t), t=0, ..., T
lmb_Im = 0.2;          % penalty for non-smoothness in the immigration probabilities, t=0, ..., T

optim_param = createOptimProblem('fmincon', 'objective', @(X)(obj_Mu_and_Im(X, Z_0, mu_covid_pdf, Im_age_struct_prob, h, totalcases_hist, [lmb_newcases lmb_R0 lmb_Im])), 'x0', [R0_daily_start, Im_mu_daily_start], 'lb', LB, 'ub', UB, 'options', optim_options);
[X_solution, ~, exitflag]=fmincon(optim_param);

[~, Y_proj] = obj_Mu_and_Im(X_solution, Z_0, mu_covid_pdf, Im_age_struct_prob, h, totalcases_hist, [lmb_newcases lmb_R0 lmb_Im]);

%% plot the estimated values
figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1200 600]);
set(gca,'FontSize',16)
subplot(1,2,1), plot(dates, Y_proj(1:2:end-1))
hold on
subplot(1,2,1), plot(dates, totalcases_hist, 'k')
xlim([dates(1), dates(end)])
xtickangle(90)
x_ticks = xticks;
xticks(x_ticks(1):7:x_ticks(end))
dateaxis('X',2)
xlabel('\bf{Date}')
ylabel('\bf{Total Cases}')
title('Total Cases: Model Fit vs Actual')
legend('Model Total Cases', 'Actual Total Cases', 'Location', 'NW')
subplot(1,2,2), plot(dates(2:end), diff(Y_proj(1:2:(length(totalcases_hist)/h))))
hold on
subplot(1,2,2), plot(dates(2:end), diff(totalcases_hist), 'k')
xlabel('\bf{Date}')
ylabel('\bf{New Cases}')
title('New Cases: Model Fit vs Actual')
legend('Model New Cases', 'Actual New Cases', 'Location', 'NW')
xlim([dates(1), dates(end)])
xtickangle(90)
x_ticks = xticks;
xticks(x_ticks(1):7:x_ticks(end))
dateaxis('X',2)
print('./Figures/Model_vs_Actual_Cases', '-dpng', '-r0')

figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1000 800]);
set(gca,'FontSize',16)
yyaxis left
plot(dates, X_solution(1:length(X_solution)/2), 'LineWidth', 2.5)
xlabel('\bf{Date}')
ylabel('\bf{R0}')
xlim([dates(1), dates(end)])
xtickangle(90)
x_ticks = xticks;
xticks(x_ticks(1):7:x_ticks(end))
dateaxis('X',2)
yyaxis right
plot(dates, X_solution(1+length(X_solution)/2:end), '--', 'LineWidth', 2.5)
ylabel('\bf{Im(t)}')
title('Estimated R0 and Immigration (Gamma dist. with mean Im(t))')
print('./Figures/Estimated_R0_and_Im', '-dpng', '-r0')

% extract the solution and adjust the solution not to have negative probability values (optimization may produce slightly negative values)
R0_hist = reshape(repmat(X_solution(1:(length(X_solution))/2), 1/h,1), length(X_solution)/2/h,1)';
Im_hist = reshape(repmat(X_solution((1+(length(X_solution)/2)):end), 1/h,1), length(X_solution)/2/h,1)';
Im_hist(Im_hist<0)=0;
R0_hist(R0_hist<0)=0;

%% MAIN SCENARIO, model of the Point process mu
% R0 - average number of infected people from a single person, conditional on that person staying infected
% distribution of the infection days is taken to be gamma-like and the point process integrates to R0:
% R0 is chosen to fit what happened already by the optimization procedure above
% the last value of R0 is assumed not to change in the future to produce a projection for the epidemic if nothing changes
R0 = [R0_hist linspace(R0_hist(end), R0_hist(end), T/h+1-length(R0_hist)-(horizon-detection_time)/h) linspace(R0_hist(end), R0_hist(end), (horizon-detection_time)/h)];

% use the estimated value of R0 as input for the simulations
mu_matrix=zeros(size(mu_covid_pdf,1), 1, T/h+1);
mu_matrix(:,1,:)=R0.*repmat(mu_covid_pdf/(sum(mu_covid_pdf)*h),1, T/h+1);
mu=@()(mu_matrix);      % the input format for mu is described in the BranchingProcessSimulator.m

% The immigration is actually the number of people who returned home without any symptoms but infected other people. The ones that were diagnosed 
% get isolated and cannot infect others. Immigration is chosen to fit what happened already by the optimization procedure above.
% If you have other hypothesis about R0 and Immigration and how they changed in time, you can try them here in the simulation and see what happens.
Im_mu = [Im_hist linspace(Im_hist(end), Im_hist(end), T/h+1-length(Im_hist)-(horizon-detection_time)/h) linspace(Im_hist(end), Im_hist(end), (horizon-detection_time)/h)];
Im_sgm = Im_mu*0.5;   % chosen so that the confidence intervals correspond to the historical volatility. We choose a model for Im, such that E(Im)/sigma(Im)=const
Im=@()(Im_function(Im_mu, Im_sgm, Im_age_struct_prob));

% we can also calculate the age structure of the population which is of interest in this case
% we can use it to calculate the percentage of people on working age, for example
% to get the age structure use: [ActiveCases, ActiveCasesByType, ActiveCasesByAge, TotalCases, TotalCasesByTypes] = BranchingProcessSimulator(sim_num, T, h, S, H, U, Z_0, mu, 'GetAgeStructure', true);
[ActiveCases, ~, ~, TotalCases, ~] = BranchingProcessSimulator(sim_num, T, h, S, H, U, Z_0, mu, Im, 'GetAgeStructure', false);
NewCases = diff(TotalCases');
% CuredCases = TotalCases - ActiveCases;

% converts from h period of time to daily period of time
NewCasesDaily = [zeros(sim_num, 1), squeeze(sum(reshape(NewCases, [2, size(NewCases,1)*h, size(NewCases,2)])))'];
TotalCasesDaily = TotalCases(:, 1:(1/h):T/h);    
ActiveCasesDaily = ActiveCases(:, 1:(1/h):T/h);

% build and save plots
buildPlots(NewCasesDaily, TotalCasesDaily, ActiveCasesDaily, newcases_hist, dates, horizon, detection_time, (1-conf_lvl_plots)/2, ...
            'MainScenario', 'No change in R_0 (no change in measures)', 'SavePlots', save_plots);

%% OPTIMISTIC SCENARIO model of the Point process mu, Optimistic Scenario, R0 changes with -0.2
R0 = [R0_hist linspace(R0_hist(end), R0_hist(end), T/h+1-length(R0_hist)-(horizon-detection_time)/h) linspace(R0_hist(end)-0.2, R0_hist(end)-0.2, (horizon-detection_time)/h)];
% use the estimated value of R0 as input for the simulations
mu_matrix=zeros(size(mu_covid_pdf,1), 1, T/h+1);
mu_matrix(:,1,:)=R0.*repmat(mu_covid_pdf/(sum(mu_covid_pdf)*h),1, T/h+1);
mu_optimistic=@()(mu_matrix);      % the input format for mu is described in the BranchingProcessSimulator.m

Im_mu = [Im_hist linspace(Im_hist(end), Im_hist(end), T/h+1-length(Im_hist)-(horizon-detection_time)/h) linspace(Im_hist(end), 0, (horizon-detection_time)/h)];
Im_optimisstic=@()(Im_function(Im_mu, Im_sgm, Im_age_struct_prob));

[ActiveCases_optimistic, ~, ~, TotalCases_optimistic, ~] = BranchingProcessSimulator(sim_num, T, h, S, H, U, Z_0, mu_optimistic, Im_optimisstic, 'GetAgeStructure', false);
NewCases_optimistic = diff(TotalCases_optimistic');
% CuredCases = TotalCases - ActiveCases;

% converts from h period of time to daily period of time
NewCasesDaily_optimistic = [zeros(sim_num, 1), squeeze(sum(reshape(NewCases_optimistic, [2, size(NewCases_optimistic,1)*h, size(NewCases_optimistic,2)])))'];
TotalCasesDaily_optimistic= TotalCases_optimistic(:, 1:(1/h):T/h);    
ActiveCasesDaily_optimistic= ActiveCases_optimistic(:, 1:(1/h):T/h);

% build and save plots
buildPlots(NewCasesDaily_optimistic, TotalCasesDaily_optimistic, ActiveCasesDaily_optimistic, newcases_hist, dates, horizon, detection_time, (1-conf_lvl_plots)/2, ...
            'OptimisticScenario', 'Decline in R_0 (better results from measures)', 'SavePlots', save_plots);

%% PESSIMISTIC SCENARIO model of the Point process mu, Pessimistic Scenario, R0 changes from 0.8 to 1.2, from now on
R0 = [R0_hist linspace(R0_hist(end), R0_hist(end), T/h+1-length(R0_hist)-(horizon-detection_time)/h) linspace(R0_hist(end)+0.5, R0_hist(end)+0.5, (horizon-detection_time)/h)];
% use the estimated value of R0 as input for the simulations
mu_matrix=zeros(size(mu_covid_pdf,1), 1, T/h+1);
mu_matrix(:,1,:)=R0.*repmat(mu_covid_pdf/(sum(mu_covid_pdf)*h),1, T/h+1);
mu_pessimistic=@()(mu_matrix);      % the input format for mu is described in the BranchingProcessSimulator.m

[ActiveCases_pessimistic, ~, ~, TotalCases_pessimistic, ~] = BranchingProcessSimulator(sim_num, T, h, S, H, U, Z_0, mu_pessimistic, Im, 'GetAgeStructure', false);
NewCases_pessimistic = diff(TotalCases_pessimistic');
% CuredCases = TotalCases - ActiveCases;

% converts from h period of time to daily period of time
NewCasesDaily_pessimistic = [zeros(sim_num, 1), squeeze(sum(reshape(NewCases_pessimistic, [2, size(NewCases_pessimistic,1)*h, size(NewCases_pessimistic,2)])))'];
TotalCasesDaily_pessimistic= TotalCases_pessimistic(:, 1:(1/h):T/h);    
ActiveCasesDaily_pessimistic= ActiveCases_pessimistic(:, 1:(1/h):T/h);

% build and save plots
buildPlots(NewCasesDaily_pessimistic, TotalCasesDaily_pessimistic, ActiveCasesDaily_pessimistic, newcases_hist, dates, horizon, detection_time, (1-conf_lvl_plots)/2, ...
            'PessimisticScenario', 'Increase in R_0 (worse results from measures)', 'SavePlots', save_plots);

%% Comparison of scenarios
[NewCasesDaily_mean, NewCasesDaily_lower, NewCasesDaily_upper, NewCasesDaily_median]=confInterval(NewCasesDaily, 0.10);
[NewCasesDaily_optimisic_mean, NewCasesDaily_optimisic_lower, NewCasesDaily_optimisic_upper, NewCasesDaily_optimisic_median]=confInterval(NewCasesDaily_optimistic, 0.10);
[NewCasesDaily_pessimistic_mean, NewCasesDaily_pessimistic_lower, NewCasesDaily_pessimistic_upper, NewCasesDaily_pessimistic_median]=confInterval(NewCasesDaily_pessimistic, 0.10);

line_wd=2.5;
figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1280 1024]);
set(gca,'FontSize',16)
hold on
h_hist=plot(dates, newcases_hist, 'Color', [0, 0, 0, 0.7],'LineWidth', 1.5);
h_main=plot(dates(1):dates(end)+horizon+detection_time+1, NewCasesDaily_median, '-', 'Color', [0, 0, 0.5, 0.5], 'LineWidth', line_wd);
h_optimistic=plot(dates(end):dates(end)+horizon+detection_time+1, NewCasesDaily_optimisic_median((dates(end)-dates(1)+1):end), '-', 'Color', [0, 0.5, 0, 0.5], 'LineWidth', line_wd);
h_pessimistic=plot(dates(end):dates(end)+horizon+detection_time+1, NewCasesDaily_pessimistic_median((dates(end)-dates(1)+1):end), '-', 'Color', [0.5, 0, 0, 0.5], 'LineWidth', line_wd);
h_CI=plot(dates(1):dates(end)+horizon+detection_time+1, NewCasesDaily_lower, '--', 'Color', [0,155/255,1,1], 'LineWidth', line_wd);
plot(dates(1):dates(end)+horizon+detection_time+1, NewCasesDaily_upper, '--', 'Color', [0,155/255,1,1], 'LineWidth', line_wd);
legend([h_main, h_optimistic, h_pessimistic, h_hist, h_CI], 'Main Scenario', 'Optimistic Scenario', 'Pessimistic Scenario', 'Observed new daily cases', '90% conf. interval', 'Location', 'NorthWest')
xtickangle(90)
x_ticks = xticks;
xticks(x_ticks(1):7:x_ticks(end))
dateaxis('X',2)
ylabel('\bf{New Daily Cases (Observed)}')
xlabel('\bf{Date}')
title('Forecasts of observed New Daily Cases (by scenario)')
if save_plots
    print(strcat('./Figures/forecast_newcases_by_scenario'), '-dpng', '-r0')
end

%% Shows the input to the branching process
%%% MU, POINT PROCESS
line_wd=2.5;
figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1280 1024]);
set(gca,'FontSize',16)
hold on
mu_forecast = squeeze(mu());
plot(0:h:omega, mu_forecast(:, end), 'Color', [0.5,0,0,0.5], 'LineWidth', line_wd);
ylabel('Point process density')
xlabel('Days')
title('Probability for spreading the infection, by days')
if save_plots
    print('./Figures/PointProcessDensity', '-dpng', '-r0')
end
%%% Infected period distribution
line_wd=2.5;
figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1280 1024]);
set(gca,'FontSize',16)
hold on
plot(0:h:omega, [diff(1-S); 0]./h, 'Color', [0,0,0.5,0.5], 'LineWidth', line_wd);
ylabel('Infected period PDF')
xlabel('Days')
title('Probability for getting cleared of the virus, by days')
if save_plots
    print('./Figures/InfectedPeriodPDF', '-dpng', '-r0')
end

figure('visible','on', 'Units','pixels','OuterPosition',[0 0 1280 1024]);
set(gca,'FontSize',16)
hold on
for i=1:1000
    Im_matrix = squeeze(Im());
    Im_matrix_Daily = sum(Im_matrix(:, 1:(1/h):T/h));
    plot(dates(1)-detection_time:dates(end)+horizon, Im_matrix_Daily, 'Color', [0.7, 0, 0,0.05], 'LineWidth', 1);
end
xtickangle(90)
x_ticks = xticks;
xticks(x_ticks(1):7:x_ticks(end))
dateaxis('X',2)
ylim([0, max(max(Im_matrix_Daily),10)])
ylabel('Immigration of undiscovered cases')
xlabel('Days')
title('Immigration Scenario')
if save_plots
    print('./Figures/ImmigrationSimulations', '-dpng', '-r0');
end

%% save the results
% save(strcat('results_', num2str(sim_num)))
